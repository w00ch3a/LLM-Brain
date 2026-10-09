#!/usr/bin/env python3
"""Real memory-on vs memory-off evaluation for LLM-Brain (coding + research).

For every task, condition (``off`` / ``on``) and repeat, a fresh temporary
root is created *outside* the bundle and output directories:

    ROOT/work   the task repository or research folder (agent cwd, git repo)
    ROOT/brain  memory-on only: an LLM-Brain vault seeded with prior-session memory
    ROOT/home   private HOME / XDG dirs for the agent
    ROOT/tmp    private TMPDIR
    ROOT/bin    the only PATH entry besides system dirs (python3, git[, llm-brain])
    ROOT/opt    memory-on only: a private copy of the installed llm-brain

``off`` and ``on`` work trees are byte-identical before the agent starts (this
is checked).  Coding tasks are graded by hidden tests copied in only after the
agent finishes; research tasks by a deterministic answer key over
``answer.json``.  No model is involved in grading.

Runners: ``codex`` (``codex exec`` in a workspace-write sandbox with network
off) and ``reference`` (scripted agent used to verify the wiring).
Standard library only.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
FORMAT = "llm-brain.real-eval"
VERSION = 1
CONDITIONS = ("off", "on")
SMOKE_TASKS = ("c01-receipt-price-format", "r02-sodium-retracted")
SYSTEM_PATH = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
OPTIONAL_PATH = ["/opt/homebrew/bin", "/usr/local/bin"]
PASS_ENV = ("USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL",
            "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR")
CITATION_RE = re.compile(r"\b[A-Z]{2}-S\d{2}\b")
GIT_ENV = {"GIT_AUTHOR_NAME": "eval", "GIT_AUTHOR_EMAIL": "eval@example.invalid", "GIT_COMMITTER_NAME": "eval",
           "GIT_COMMITTER_EMAIL": "eval@example.invalid", "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}


class EvalError(Exception):
    pass


# --------------------------------------------------------------------------- tasks

def load_tasks(tasks_dir: Path) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for name in ("coding", "research"):
        spec = importlib.util.spec_from_file_location(f"real_eval_{name}", tasks_dir / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        tasks.extend(module.TASKS)
    seen = set()
    for task in tasks:
        if task["id"] in seen:
            raise EvalError(f"duplicate task id {task['id']}")
        seen.add(task["id"])
        if task["kind"] not in ("memory", "control", "harm-control"):
            raise EvalError(f"{task['id']}: bad kind")
    return tasks


def base_prompt(task: dict[str, Any]) -> str:
    if task["family"] == "coding":
        return (
            "You are working in a small Python repository (the current directory).\n\n"
            f"Task: {task['prompt']}\n\n"
            "Work only inside this directory. Keep the change minimal and do not add new dependencies. "
            "There is no network access. When you are done, reply with a one-line summary."
        )
    schema = json.dumps(task["schema"], ensure_ascii=False)
    return (
        "You are helping with a research project. The collected source excerpts are in ./sources; each file carries a Source ID.\n\n"
        f"Question: {task['question']}\n\n"
        f"Write your answer to ./answer.json as one JSON object with exactly these keys (value descriptions shown): {schema}\n"
        "Cite only source IDs you have actually seen; never invent IDs. There is no network access. "
        "Work only inside this directory. When you are done, reply with a one-line summary."
    )


def memory_block(task: dict[str, Any], mode: str, injected: str | None) -> str:
    pid = task["project_id"]
    if mode == "inject":
        return (
            "\n\nProject memory from earlier sessions (LLM-Brain context pack for this task). "
            "Memory can be out of date: if the current files contradict it, the files win.\n\n"
            f"<project-memory>\n{injected or ''}\n</project-memory>"
        )
    return (
        "\n\nProject memory: notes from earlier sessions on this project are available through the `llm-brain` "
        f"command (project id: {pid}). Before you start, run:\n"
        f"  llm-brain brief {pid}\n"
        f"  llm-brain pack build {pid} --task \"<your task in a few words>\"   (prints file=PATH; read that file)\n"
        f"and use `llm-brain search {pid} \"<query>\"` for anything specific. "
        "Memory can be out of date: if the current files contradict it, the files win."
    )


def fairness_problems(task: dict[str, Any]) -> list[str]:
    problems = []
    corpus = "\n".join(task["files"].values()) + "\n" + base_prompt(task)
    for marker in task.get("memory_only", []):
        if marker.lower() in corpus.lower():
            problems.append(f"memory-only marker {marker!r} is discoverable without memory")
    return problems


# --------------------------------------------------------------------------- install

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def install_llm_brain(bundle: Path) -> dict[str, Path]:
    archives = sorted((bundle / "dist").glob("llm-brain-*-standalone.tar.gz"))
    if len(archives) != 1:
        raise EvalError("expected exactly one dist/llm-brain-*-standalone.tar.gz in the bundle")
    archive = archives[0]
    expected = (archive.parent / (archive.name + ".sha256")).read_text().split()[0]
    if sha256_file(archive) != expected:
        raise EvalError("standalone archive checksum mismatch")
    target = bundle / ".local" / archive.name.replace("-standalone.tar.gz", "")
    marker = target / ".installed"
    if not (marker.is_file() and marker.read_text().strip() == expected):
        shutil.rmtree(target, ignore_errors=True)
        target.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                name = member.name
                if name.startswith("/") or ".." in Path(name).parts or member.issym() or member.islnk():
                    raise EvalError(f"unsafe archive member {name}")
            tar.extractall(target)
        marker.write_text(expected + "\n")
    cli = target / "llm-brain" / "bin" / "llm-brain"
    if not cli.is_file():
        raise EvalError("installed archive has no llm-brain/bin/llm-brain")
    vendor = bundle / "vendor"
    if not (vendor / "yaml" / "__init__.py").is_file():
        raise EvalError("bundle is missing vendor/yaml (PyYAML)")
    return {"tree": target / "llm-brain", "cli": cli, "vendor": vendor, "archive_sha256": Path(expected)}


def write_exec(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def private_install(install: dict[str, Path], root: Path, python3: str) -> Path:
    """Copy llm-brain into ROOT/opt so nothing points the agent at the bundle."""
    opt = root / "opt"
    shutil.copytree(install["tree"], opt / "llm-brain")
    shutil.copytree(install["vendor"], opt / "vendor")
    write_exec(opt / "python", f'#!/bin/sh\nPYTHONPATH="{opt}/vendor${{PYTHONPATH:+:$PYTHONPATH}}" exec "{python3}" "$@"\n')
    return opt / "llm-brain" / "bin" / "llm-brain"


# --------------------------------------------------------------------------- run root

def run(cmd: list[str], cwd: Path, env: dict[str, str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def tree_hash(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def base_env(root: Path) -> dict[str, str]:
    env = {key: os.environ[key] for key in PASS_ENV if key in os.environ}
    path = [str(root / "bin")] + SYSTEM_PATH + [d for d in OPTIONAL_PATH if Path(d).is_dir() and not (Path(d) / "llm-brain").exists()]
    env.update({
        "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "PATH": ":".join(path), "TERM": "dumb",
        "XDG_STATE_HOME": str(root / "home" / ".local" / "state"), "XDG_DATA_HOME": str(root / "home" / ".local" / "share"),
        "XDG_CONFIG_HOME": str(root / "home" / ".config"), "XDG_CACHE_HOME": str(root / "home" / ".cache"),
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    env.setdefault("LANG", "en_US.UTF-8")
    return env


def tool_links(root: Path, extra: dict[str, str]) -> None:
    bin_dir = root / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name in ("python3", "git"):
        found = shutil.which(name)
        if not found:
            raise EvalError(f"{name} not found on PATH")
        os.symlink(os.path.realpath(found), bin_dir / name)
    for name, target in extra.items():
        os.symlink(target, bin_dir / name)


def seed_brain(cli: Path, root: Path, task: dict[str, Any], env: dict[str, str]) -> None:
    brain, work, pid = root / "brain", root / "work", task["project_id"]
    def cli_run(*args: str) -> str:
        done = run([str(cli), "--root", str(brain), *args], work, env, 180)
        if done.returncode != 0:
            raise EvalError(f"seed: llm-brain {' '.join(args[:2])} failed: {done.stderr.strip()[-400:]}")
        return done.stdout
    cli_run("project", "ensure", str(work), "--id", pid)
    claims = brain / "projects" / pid / "okf" / "claims"
    for record in task["memory"]:
        lines = ["---", "type: Claim", f"title: {json.dumps(record['title'])}", "status: stable",
                 'generated: {by: "human:prior-session", at: "2026-01-01T00:00:00Z"}',
                 'sources: [{resource: "prior session notes"}]',
                 f"brain_project_id: {pid}", "brain_review_state: approved", "brain_source_authority: human-directive",
                 "brain_sensitivity: internal"]
        if record.get("paths"):
            lines.append("brain_paths: [" + ", ".join(json.dumps(p) for p in record["paths"]) + "]")
        if record.get("observed_at"):
            lines.append(f"brain_observed_at: {json.dumps(record['observed_at'])}")
        if record.get("supersedes"):
            lines.append(f"brain_supersedes: {record['supersedes']}")
        lines += ["brain_schema_version: 3", "---", f"# {record['title']}", "", record["text"], ""]
        (claims / f"{record['id']}.md").write_text("\n".join(lines), encoding="utf-8")
    for record in task["memory"]:
        if record.get("retract"):
            preview = cli_run("retract", pid, record["id"], "--reason", record["retract"], "--preview")
            token = re.search(r"token=([0-9a-f]{64})", preview)
            if not token:
                raise EvalError("seed: retraction preview returned no token")
            cli_run("retract", pid, record["id"], "--reason", record["retract"], "--confirm", token.group(1))
    for intention in task.get("intentions", []):
        cli_run("intention", "add", pid, "--action", intention["action"], "--trigger", intention["trigger"])
    cli_run("index", "build", pid)


def materialise(task: dict[str, Any], condition: str, install: dict[str, Path] | None, scratch: Path | None) -> dict[str, Any]:
    root = Path(tempfile.mkdtemp(prefix="lbre-", dir=str(scratch) if scratch else None)).resolve()
    for sub in ("work", "home", "tmp"):
        (root / sub).mkdir()
    work = root / "work"
    for rel, content in task["files"].items():
        target = work / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    env = base_env(root)
    git_env = dict(env, **GIT_ENV)
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"], ["git", "commit", "-q", "-m", "Initial import"]):
        done = run([shutil.which(cmd[0]) or cmd[0], *cmd[1:]], work, git_env)
        if done.returncode != 0:
            raise EvalError(f"git setup failed: {done.stderr.strip()}")
    pre_hash = tree_hash(work)
    extra: dict[str, str] = {}
    cli = None
    if condition == "on":
        assert install is not None
        cli = private_install(install, root, os.path.realpath(shutil.which("python3") or "python3"))
        env["LLM_BRAIN_ROOT"] = str(root / "brain")
        env["LLM_BRAIN_OKF_PYTHON"] = str(root / "opt" / "python")
        seed_brain(cli, root, task, env)
        shim = root / "opt" / "llm-brain-shim"
        log = root / "home" / "llm-brain-calls.log"
        write_exec(shim, (
            "#!/bin/sh\n"
            f'export LLM_BRAIN_ROOT="{root}/brain" LLM_BRAIN_OKF_PYTHON="{root}/opt/python"\n'
            f'"{cli}" "$@"\nstatus=$?\n'
            f'printf "%s\\t%s\\n" "$status" "$*" >>"{log}" 2>/dev/null || true\n'
            "exit $status\n"))
        extra["llm-brain"] = str(shim)
    tool_links(root, extra)
    if tree_hash(work) != pre_hash:
        raise EvalError("seeding changed the work tree")
    return {"root": root, "work": work, "env": env, "cli": cli, "work_hash": pre_hash}


# --------------------------------------------------------------------------- runners

def walk(value: Any):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def parse_events(text: str) -> dict[str, Any]:
    commands, usage_turns, totals = [], [], None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        for node in walk(event):
            command = node.get("command")
            if isinstance(command, list):
                command = " ".join(str(part) for part in command)
            if isinstance(command, str):
                commands.append({"command": command[:500], "exit_code": node.get("exit_code")})
            if node.get("type") == "turn.completed" and isinstance(node.get("usage"), dict):
                usage_turns.append(node["usage"])
            if isinstance(node.get("total_token_usage"), dict):
                totals = node["total_token_usage"]
    usage = None
    if usage_turns:
        usage = {key: sum(int(turn.get(key) or 0) for turn in usage_turns) for key in ("input_tokens", "cached_input_tokens", "output_tokens")}
    elif totals:
        usage = {key: int(totals.get(key) or 0) for key in ("input_tokens", "cached_input_tokens", "output_tokens")}
    seen, unique = set(), []
    for entry in commands:
        key = entry["command"]
        if key not in seen:
            seen.add(key)
            unique.append(entry)
    return {"commands": unique, "usage": usage}


def run_process(cmd: list[str], cwd: Path, env: dict[str, str], timeout: int, stdout_path: Path) -> tuple[int | None, bool, str]:
    with stdout_path.open("w", encoding="utf-8") as out:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            _, err = proc.communicate(timeout=timeout)
            return proc.returncode, False, err or ""
        except subprocess.TimeoutExpired:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(proc.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    proc.wait(timeout=10)
                    break
                except subprocess.TimeoutExpired:
                    continue
            _, err = proc.communicate()
            return None, True, err or ""


class CodexRunner:
    name = "codex"

    def __init__(self, args: argparse.Namespace, output: Path, dry_run: bool = False) -> None:
        self.codex = Path(os.path.expanduser(args.codex)).resolve()
        if not self.codex.is_file():
            raise EvalError(f"codex not found at {args.codex}")
        self.model, self.extra_config, self.extra_args = args.model, args.codex_config, args.codex_arg
        env = dict(os.environ)
        help_text = run([str(self.codex), "exec", "--help"], Path.cwd(), env, 60)
        self.help = help_text.stdout + help_text.stderr
        if "--sandbox" not in self.help:
            raise EvalError("this codex has no `exec --sandbox`; refusing to run unsandboxed")
        version = run([str(self.codex), "--version"], Path.cwd(), env, 60)
        self.version = (version.stdout or version.stderr).strip()
        self.node = None
        head = self.codex.read_bytes()[:200]
        if head.startswith(b"#!") and b"node" in head.split(b"\n", 1)[0]:
            self.node = shutil.which("node")
            if not self.node:
                raise EvalError("codex is a node script but node is not on PATH")
        self.codex_home: Path | None = None
        self.isolated = args.codex_home == "isolated" and not dry_run
        self.auth = Path(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")) / "auth.json"
        if self.isolated and not self.auth.is_file() and not (os.environ.get("OPENAI_API_KEY") or os.environ.get("CODEX_API_KEY")):
            raise EvalError(f"no {self.auth} to copy into the isolated CODEX_HOME and no API key in the environment; "
                            "log in with `codex login`, or rerun with --codex-home shared")
        self.output = output

    def prepare_home(self) -> None:
        """Private CODEX_HOME: only auth.json is copied; no config, AGENTS.md, MCP servers or plugins."""
        if not self.isolated:
            return
        home = self.output / ".codex-home"
        home.mkdir(mode=0o700, exist_ok=True)
        if self.auth.is_file():
            shutil.copyfile(self.auth, home / "auth.json")
            (home / "auth.json").chmod(0o600)
        self.codex_home = home

    def cleanup(self) -> None:
        if self.codex_home:
            shutil.rmtree(self.codex_home, ignore_errors=True)

    def has(self, flag: str) -> bool:
        return flag in self.help

    def command(self, root: Path, prompt: str) -> list[str]:
        cmd = [str(self.codex), "exec"]
        if self.has("--skip-git-repo-check"):
            cmd.append("--skip-git-repo-check")
        cmd += ["--sandbox", "workspace-write"]
        if self.has("--cd"):
            cmd += ["--cd", str(root / "work")]
        if self.has("--json"):
            cmd.append("--json")
        if self.has("--output-last-message"):
            cmd += ["--output-last-message", str(root / "last-message.txt")]
        writable = json.dumps([str(root / "brain"), str(root / "tmp"), str(root / "home")])
        cmd += ["-c", "sandbox_workspace_write.network_access=false",
                "-c", f"sandbox_workspace_write.writable_roots={writable}",
                "-c", 'approval_policy="never"']
        if self.model:
            cmd += ["-m", self.model]
        for item in self.extra_config:
            cmd += ["-c", item]
        cmd += list(self.extra_args)
        cmd.append(prompt)
        return cmd

    def env(self, env: dict[str, str]) -> dict[str, str]:
        env = dict(env)
        # HOME is private per run, so always name the Codex home explicitly.
        env["CODEX_HOME"] = str(self.codex_home) if self.codex_home else str(self.auth.parent)
        return env

    def links(self) -> dict[str, str]:
        return {"node": os.path.realpath(self.node)} if self.node else {}

    def invoke(self, root: Path, prompt: str, task: dict[str, Any], condition: str, timeout: int) -> dict[str, Any]:
        events = root / "events.jsonl"
        code, timed_out, err = run_process(self.command(root, prompt), root / "work", self.env(dict_env(root)), timeout, events)
        parsed = parse_events(events.read_text(encoding="utf-8", errors="replace"))
        last = root / "last-message.txt"
        return {"exit_code": code, "timed_out": timed_out, "stderr_tail": err[-1500:], "commands": parsed["commands"],
                "usage": parsed["usage"], "last_message": last.read_text(encoding="utf-8", errors="replace") if last.is_file() else ""}

    def preflight(self, scratch: Path | None, timeout: int) -> None:
        root = Path(tempfile.mkdtemp(prefix="lbre-preflight-", dir=str(scratch) if scratch else None)).resolve()
        try:
            for sub in ("work", "home", "tmp", "brain"):
                (root / sub).mkdir()
            tool_links(root, self.links())
            ENV_CACHE[str(root)] = base_env(root)
            result = self.invoke(root, "Reply with exactly the word READY and nothing else. Do not run any commands.", {}, "off", timeout)
            if result["exit_code"] != 0 or "READY" not in (result["last_message"] or "") + json.dumps(result["commands"]):
                raise EvalError("codex preflight failed (auth, model or sandbox). stderr tail:\n" + result["stderr_tail"])
        finally:
            shutil.rmtree(root, ignore_errors=True)


class ReferenceRunner:
    name = "reference"
    version = "scripted-reference"

    def links(self) -> dict[str, str]:
        return {}

    def prepare_home(self) -> None:
        pass

    def cleanup(self) -> None:
        pass

    def preflight(self, scratch: Path | None, timeout: int) -> None:
        pass

    def invoke(self, root: Path, prompt: str, task: dict[str, Any], condition: str, timeout: int) -> dict[str, Any]:
        spec = root / "reference.json"
        spec.write_text(json.dumps({"task": task, "condition": condition}), encoding="utf-8")
        (root / "prompt.txt").write_text(prompt, encoding="utf-8")
        events = root / "events.jsonl"
        code, timed_out, err = run_process([sys.executable, str(HERE / "reference_agent.py"), str(spec)], root / "work", dict_env(root), timeout, events)
        spec.unlink()
        parsed = parse_events(events.read_text(encoding="utf-8"))
        return {"exit_code": code, "timed_out": timed_out, "stderr_tail": err[-1500:], "commands": parsed["commands"], "usage": None, "last_message": ""}


ENV_CACHE: dict[str, dict[str, str]] = {}


def dict_env(root: Path) -> dict[str, str]:
    return dict(ENV_CACHE[str(root)])


# --------------------------------------------------------------------------- grading

def field(obj: Any, dotted: str) -> Any:
    for part in dotted.split("."):
        if not isinstance(obj, dict) or part not in obj:
            return None
        obj = obj[part]
    return obj


def as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        return " | ".join(as_text(v) for v in value)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def equals(actual: Any, expected: Any) -> bool:
    if isinstance(expected, bool):
        if isinstance(actual, bool):
            return actual is expected
        return isinstance(actual, str) and actual.strip().lower() in (("true", "yes") if expected else ("false", "no"))
    if isinstance(expected, (int, float)):
        try:
            return abs(float(str(actual).replace(",", "").strip().rstrip("%")) - float(expected)) < 1e-9
        except (TypeError, ValueError):
            return False
    return as_text(actual).strip().lower() == str(expected).strip().lower()


def cited_ids(answer: dict[str, Any]) -> tuple[set[str], list[str]]:
    ids, unbacked = set(), []
    for item in answer.get("citations") or []:
        found = CITATION_RE.findall(str(item).upper())
        if not found:
            unbacked.append(str(item)[:80])
        ids.update(found)
    return ids, unbacked


def load_answer(work: Path, last_message: str) -> tuple[dict[str, Any] | None, str]:
    path = work / "answer.json"
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data, "answer.json"
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
    for match in reversed(list(re.finditer(r"\{.*\}", last_message or "", re.S))):
        try:
            data = json.loads(match.group(0))
            if isinstance(data, dict):
                return data, "last-message"
        except json.JSONDecodeError:
            continue
    return None, "missing"


def grade_research(task: dict[str, Any], work: Path, last_message: str) -> dict[str, Any]:
    answer, origin = load_answer(work, last_message)
    checks: list[dict[str, Any]] = []
    if answer is None:
        return {"passed": False, "score": 0.0, "answer_source": origin, "checks": [{"check": "answer present", "ok": False}], "answer": None}
    missing = [key for key in task["schema"] if key not in answer]
    checks.append({"check": "schema keys present", "ok": not missing, "detail": missing})
    ids, unbacked = cited_ids(answer)
    mentioned = set(CITATION_RE.findall(as_text(answer)))
    invented = sorted((ids | mentioned) - set(task["allowed_citations"]))
    checks.append({"check": "no invented sources", "ok": not invented and not unbacked, "detail": invented + unbacked})
    for spec in task["checks"]:
        if "citations_include" in spec:
            lacking = sorted(set(spec["citations_include"]) - ids)
            checks.append({"check": f"cites {spec['citations_include']}", "ok": not lacking, "detail": lacking})
        elif "citations_exclude" in spec:
            bad = sorted(set(spec["citations_exclude"]) & ids)
            label = f"does not cite {spec['citations_exclude']}"
            if bad and spec.get("unless_regex"):
                # Citing a withdrawn source is fine when the answer says it is
                # withdrawn; the rule is "never as support", not "never name it".
                label += f" unless answer =~ /{spec['unless_regex']}/"
                if re.search(spec["unless_regex"], as_text(answer), re.I):
                    bad = []
            checks.append({"check": label, "ok": not bad, "detail": bad})
        else:
            value = field(answer, spec["field"])
            if "equals" in spec:
                ok = equals(value, spec["equals"])
                label = f"{spec['field']} == {spec['equals']!r}"
            elif "is_null" in spec:
                ok = value is None or (isinstance(value, str) and value.strip().lower() in ("", "null", "none", "n/a"))
                label = f"{spec['field']} is null"
            elif "regex" in spec:
                ok = re.search(spec["regex"], as_text(value), re.I) is not None
                label = f"{spec['field']} =~ /{spec['regex']}/"
            else:
                ok = re.search(spec["not_regex"], as_text(value), re.I) is None
                label = f"{spec['field']} !~ /{spec['not_regex']}/"
            checks.append({"check": label, "ok": ok, "detail": as_text(value)[:200]})
    passed = sum(1 for c in checks if c["ok"])
    return {"passed": passed == len(checks), "score": round(passed / len(checks), 4), "answer_source": origin, "checks": checks, "answer": answer}


def grade_coding(task: dict[str, Any], root: Path, env: dict[str, str]) -> dict[str, Any]:
    grade = root / "grade"
    shutil.copytree(root / "work", grade, ignore=shutil.ignore_patterns(".git", "__pycache__"))
    test = grade / "_real_eval_hidden_test.py"
    test.write_text(task["hidden_test"], encoding="utf-8")
    try:
        done = run([os.path.realpath(shutil.which("python3") or "python3"), test.name], grade, env, 120)
        ok, tail = done.returncode == 0, (done.stdout + done.stderr)[-1500:]
    except subprocess.TimeoutExpired:
        ok, tail = False, "hidden test timed out"
    return {"passed": ok, "score": 1.0 if ok else 0.0, "test_output_tail": tail}


# --------------------------------------------------------------------------- one run

def one_run(item: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    task, condition, repeat = item["task"], item["condition"], item["repeat"]
    row: dict[str, Any] = {"run_id": item["run_id"], "task_id": task["id"], "family": task["family"], "kind": task["kind"],
                           "knowledge": task["knowledge"], "condition": condition, "repeat": repeat}
    started = time.monotonic()
    run_dir = ctx["output"] / "runs" / item["run_id"]
    run_dir.mkdir(parents=True, exist_ok=True)
    root = None
    try:
        prepared = materialise(task, condition, ctx["install"], ctx["scratch"])
        root = prepared["root"]
        for name, target in ctx["runner"].links().items():
            os.symlink(target, root / "bin" / name)
        ENV_CACHE[str(root)] = prepared["env"]
        row["work_hash"] = prepared["work_hash"]
        prompt = base_prompt(task)
        if condition == "on":
            injected = None
            if ctx["memory_mode"] == "inject":
                pack = run([str(prepared["cli"]), "pack", "build", task["project_id"], "--task", task.get("prompt") or task.get("question")], root / "work", prepared["env"], 120)
                pack_file = re.search(r"file=(\S+)", pack.stdout)
                injected = Path(pack_file.group(1)).read_text(encoding="utf-8") if pack_file else pack.stdout
            prompt += memory_block(task, ctx["memory_mode"], injected)
        (run_dir / "prompt.txt").write_text(prompt, encoding="utf-8")
        if ctx["dry_run"]:
            if isinstance(ctx["runner"], CodexRunner):
                (run_dir / "command.txt").write_text(json.dumps(ctx["runner"].command(root, prompt)), encoding="utf-8")
            row.update(passed=None, score=None, dry_run=True)
            return row
        agent_started = time.monotonic()
        result = ctx["runner"].invoke(root, prompt, task, condition, ctx["timeout"])
        row["agent_seconds"] = round(time.monotonic() - agent_started, 2)
        row.update(exit_code=result["exit_code"], timed_out=result["timed_out"], usage=result["usage"])
        commands = result["commands"]
        row["commands_total"] = len(commands)
        memory_cmds = [c for c in commands if "llm-brain" in c["command"]]
        row["memory_commands"] = len(memory_cmds)
        calls_log = root / "home" / "llm-brain-calls.log"
        calls = [line.split("\t", 1) for line in calls_log.read_text().splitlines()] if calls_log.is_file() else []
        row["memory_calls_logged"] = len(calls)
        row["memory_calls_failed"] = sum(1 for status, _ in calls if status != "0")
        flags = []
        for c in commands:
            text = c["command"]
            if str(ctx["bundle"]) in text or str(ctx["output"]) in text:
                flags.append("touched-bundle-or-output")
            if "lbre-" in text and str(root) not in text:
                flags.append("touched-other-run-root")
        if condition == "off" and memory_cmds:
            flags.append("memory-command-in-off-condition")
        if condition == "on" and memory_cmds and not calls and not ctx["reference"]:
            flags.append("memory-calls-not-logged(sandbox-writable-roots?)")
        row["contamination_flags"] = sorted(set(flags))
        if task["family"] == "coding":
            row.update(grade_coding(task, root, prepared["env"]))
            diff = run(["git", "diff", "--stat"], root / "work", prepared["env"])
            full = run(["git", "diff"], root / "work", prepared["env"])
            (run_dir / "diff.patch").write_text(full.stdout, encoding="utf-8")
            row["diff_stat"] = diff.stdout.strip().splitlines()[-1:] if diff.stdout.strip() else []
        else:
            graded = grade_research(task, root / "work", result["last_message"])
            (run_dir / "answer.json").write_text(json.dumps(graded.pop("answer"), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            row.update(graded)
        for name in ("events.jsonl", "last-message.txt"):
            if (root / name).is_file():
                shutil.copyfile(root / name, run_dir / name)
        if result["stderr_tail"]:
            (run_dir / "stderr.txt").write_text(result["stderr_tail"], encoding="utf-8")
        (run_dir / "commands.json").write_text(json.dumps(commands, indent=2) + "\n", encoding="utf-8")
        row["error"] = None
    except Exception as error:  # noqa: BLE001 - recorded per run
        row.update(passed=False, score=0.0, error=f"{type(error).__name__}: {error}"[:800])
    finally:
        row["elapsed_seconds"] = round(time.monotonic() - started, 2)
        if root is not None:
            ENV_CACHE.pop(str(root), None)
            if not ctx["keep"]:
                shutil.rmtree(root, ignore_errors=True)
            else:
                row["root"] = str(root)
    return row


# --------------------------------------------------------------------------- report

def rate(rows: list[dict[str, Any]]) -> float | None:
    graded = [r for r in rows if r.get("passed") is not None]
    return round(sum(1 for r in graded if r["passed"]) / len(graded), 4) if graded else None


def bootstrap_ci(deltas: list[float], seed: int = 7, rounds: int = 4000) -> tuple[float, float] | None:
    if len(deltas) < 2:
        return None
    rng = random.Random(seed)
    means = sorted(statistics.fmean(rng.choice(deltas) for _ in deltas) for _ in range(rounds))
    return round(means[int(0.025 * rounds)], 4), round(means[int(0.975 * rounds) - 1], 4)


def summarise(rows: list[dict[str, Any]], tasks: list[dict[str, Any]], meta: dict[str, Any]) -> tuple[dict[str, Any], str]:
    by_task: dict[str, dict[str, Any]] = {}
    for task in tasks:
        task_rows = [r for r in rows if r["task_id"] == task["id"]]
        if not task_rows:
            continue
        entry = {"family": task["family"], "kind": task["kind"], "knowledge": task["knowledge"]}
        for condition in CONDITIONS:
            cond_rows = [r for r in task_rows if r["condition"] == condition]
            entry[condition] = {"passed": sum(1 for r in cond_rows if r.get("passed")), "runs": len(cond_rows), "rate": rate(cond_rows),
                                "mean_score": round(statistics.fmean(r.get("score") or 0 for r in cond_rows), 4) if cond_rows else None}
        if entry["on"]["rate"] is not None and entry["off"]["rate"] is not None:
            entry["delta"] = round(entry["on"]["rate"] - entry["off"]["rate"], 4)
        by_task[task["id"]] = entry
    families: dict[str, Any] = {}
    for family in ("coding", "research"):
        fam = {}
        for group, kinds in (("memory", ("memory",)), ("controls", ("control", "harm-control"))):
            group_rows = [r for r in rows if r["family"] == family and r["kind"] in kinds]
            if not group_rows:
                continue
            deltas = [e["delta"] for t, e in by_task.items() if e["family"] == family and e["kind"] in kinds and "delta" in e]
            fam[group] = {"on": rate([r for r in group_rows if r["condition"] == "on"]), "off": rate([r for r in group_rows if r["condition"] == "off"]),
                          "tasks": len(deltas), "mean_task_delta": round(statistics.fmean(deltas), 4) if deltas else None,
                          "delta_ci95_bootstrap_over_tasks": bootstrap_ci(deltas)}
        families[family] = fam
    def agg(condition: str, key: str) -> float | None:
        values = [r["usage"][key] for r in rows if r["condition"] == condition and r.get("usage")]
        return round(statistics.fmean(values)) if values else None
    def mean(condition: str, key: str) -> float | None:
        values = [r[key] for r in rows if r["condition"] == condition and isinstance(r.get(key), (int, float))]
        return round(statistics.fmean(values), 2) if values else None
    cost = {c: {"mean_agent_seconds": mean(c, "agent_seconds"), "mean_input_tokens": agg(c, "input_tokens"),
                "mean_cached_input_tokens": agg(c, "cached_input_tokens"), "mean_output_tokens": agg(c, "output_tokens"),
                "mean_commands": mean(c, "commands_total")} for c in CONDITIONS}
    on_rows = [r for r in rows if r["condition"] == "on" and r.get("passed") is not None]
    memory_use = {"runs_using_llm_brain": sum(1 for r in on_rows if r.get("memory_commands")), "on_runs": len(on_rows),
                  "failed_llm_brain_calls": sum(r.get("memory_calls_failed") or 0 for r in on_rows)}
    harms = sorted(t for t, e in by_task.items() if e.get("delta", 0) < 0)
    flagged = sorted({r["run_id"] for r in rows if r.get("contamination_flags")})
    errors = sorted({f"{r['run_id']}: {r['error']}" for r in rows if r.get("error")})
    hashes: dict[str, set] = {}
    for r in rows:
        if r.get("work_hash"):
            hashes.setdefault(r["task_id"], set()).add(r["work_hash"])
    unfair = sorted(t for t, h in hashes.items() if len(h) > 1)
    summary = {"format": FORMAT, "version": VERSION, "meta": meta, "families": families, "tasks": by_task, "cost": cost,
               "memory_use": memory_use, "regressions": harms, "contamination_flagged_runs": flagged, "errors": errors,
               "unequal_work_trees": unfair}

    def pct(value: float | None) -> str:
        return "n/a" if value is None else f"{value * 100:.0f}%"
    lines = [f"# LLM-Brain real evaluation: memory on vs off", "",
             f"- Runner: {meta['runner']} ({meta.get('runner_version', '')}); model: {meta.get('model') or 'codex default'}; memory mode: {meta['memory_mode']}",
             f"- LLM-Brain archive sha256: {meta['llm_brain_archive_sha256']}", f"- Repeats: {meta['repeats']}; seed: {meta['seed']}; runs: {len(rows)}; started {meta['started']}", ""]
    lines += ["## Pass rates", "", "| Family | Group | On | Off | Mean task delta | 95% CI (bootstrap over tasks) |", "|---|---|---|---|---|---|"]
    for family, fam in families.items():
        for group, g in fam.items():
            ci = g["delta_ci95_bootstrap_over_tasks"]
            md = "n/a" if g["mean_task_delta"] is None else "%+.0f pts" % (g["mean_task_delta"] * 100)
            ci_text = "n/a" if not ci else "%+.0f to %+.0f pts" % (ci[0] * 100, ci[1] * 100)
            lines.append(f"| {family} | {group} ({g['tasks']} tasks) | {pct(g['on'])} | {pct(g['off'])} | {md} | {ci_text} |")
    lines += ["", "## Per task", "", "| Task | Family | Kind | Knowledge | On | Off | Delta | On score | Off score |", "|---|---|---|---|---|---|---|---|---|"]
    for task_id, e in by_task.items():
        delta = e.get("delta")
        delta_text = "n/a" if delta is None else "%+.0f" % (delta * 100)
        lines.append(f"| {task_id} | {e['family']} | {e['kind']} | {e['knowledge']} | {e['on']['passed']}/{e['on']['runs']} | {e['off']['passed']}/{e['off']['runs']} | "
                     f"{delta_text} | {e['on']['mean_score']} | {e['off']['mean_score']} |")
    lines += ["", "## Cost", "", "| Condition | Mean agent seconds | Mean input tokens | Mean cached input | Mean output tokens | Mean commands |", "|---|---|---|---|---|---|"]
    for c in CONDITIONS:
        k = cost[c]
        lines.append(f"| {c} | {k['mean_agent_seconds']} | {k['mean_input_tokens']} | {k['mean_cached_input_tokens']} | {k['mean_output_tokens']} | {k['mean_commands']} |")
    lines += ["", "## Integrity", "",
              f"- Memory-on runs that called llm-brain: {memory_use['runs_using_llm_brain']}/{memory_use['on_runs']}; failed llm-brain calls: {memory_use['failed_llm_brain_calls']}",
              f"- Tasks where memory hurt (on < off): {', '.join(harms) or 'none'}",
              f"- Runs with contamination flags: {', '.join(flagged) or 'none'}",
              f"- Tasks whose off/on work trees differed before the agent ran: {', '.join(unfair) or 'none'}",
              f"- Errored runs: {len(errors)}"]
    lines += [f"  - {e}" for e in errors[:20]]
    lines += ["", "Scoring: coding = hidden executable tests; research = deterministic answer key over answer.json "
              "(required facts, superseded/retracted facts absent, required citations, no invented source IDs). No model grades anything."]
    return summary, "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- main

def main() -> int:
    if sys.version_info < (3, 9):
        raise SystemExit("python3 >= 3.9 is required")
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--output", required=True, help="results directory (new, or existing with --resume)")
    parser.add_argument("--bundle", default=str(HERE), help="bundle directory holding dist/, vendor/ and tasks/")
    parser.add_argument("--runner", choices=("codex", "reference"), default="codex")
    default_codex = os.path.expanduser("~/.local/bin/codex")
    parser.add_argument("--codex", default=default_codex if os.path.isfile(default_codex) else (shutil.which("codex") or default_codex))
    parser.add_argument("--model", default=None)
    parser.add_argument("--codex-config", action="append", default=[], metavar="KEY=VALUE", help="extra `codex exec -c` overrides")
    parser.add_argument("--codex-arg", action="append", default=[], help="extra raw argument for codex exec")
    parser.add_argument("--codex-home", choices=("isolated", "shared"), default="isolated")
    parser.add_argument("--memory-mode", choices=("cli", "inject"), default="cli")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=900, help="seconds per agent run")
    parser.add_argument("--tasks", default="", help="comma-separated task ids (default: all)")
    parser.add_argument("--family", choices=("coding", "research"), default=None)
    parser.add_argument("--smoke", action="store_true", help="one task per family, one repeat")
    parser.add_argument("--dry-run", action="store_true", help="prepare and seed everything, write prompts/commands, call no agent")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--keep-roots", action="store_true")
    parser.add_argument("--scratch", default=None, help="parent for per-run temp roots (default: system temp)")
    parser.add_argument("--skip-preflight", action="store_true")
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()

    bundle = Path(args.bundle).resolve()
    output = Path(args.output).resolve()
    tasks = load_tasks(bundle / "tasks")
    if args.smoke:
        args.tasks, args.repeats = ",".join(SMOKE_TASKS), 1
    if args.tasks:
        wanted = [t.strip() for t in args.tasks.split(",") if t.strip()]
        unknown = set(wanted) - {t["id"] for t in tasks}
        if unknown:
            raise SystemExit(f"unknown task ids: {sorted(unknown)}")
        tasks = [t for t in tasks if t["id"] in wanted]
    if args.family:
        tasks = [t for t in tasks if t["family"] == args.family]
    results_path = output / "results.jsonl"
    if args.report_only:
        rows = [json.loads(line) for line in results_path.read_text().splitlines() if line.strip()]
        meta = json.loads((output / "meta.json").read_text())
        summary, markdown = summarise(rows, load_tasks(bundle / "tasks"), meta)
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        (output / "summary.md").write_text(markdown)
        print(markdown)
        return 0

    problems = [f"{t['id']}: {p}" for t in tasks for p in fairness_problems(t)]
    if problems:
        print("fairness check failed:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 65
    if output.exists() and not args.resume:
        print(f"output exists: {output} (use --resume to continue)", file=sys.stderr)
        return 65
    runner = CodexRunner(args, output, args.dry_run) if args.runner == "codex" else ReferenceRunner()
    install = install_llm_brain(bundle)
    output.mkdir(parents=True, exist_ok=True)
    runner.prepare_home()
    scratch = Path(args.scratch).resolve() if args.scratch else None
    if scratch:
        scratch.mkdir(parents=True, exist_ok=True)
    seed = args.seed if args.seed is not None else random.SystemRandom().randrange(1 << 30)
    meta = {"runner": runner.name, "runner_version": getattr(runner, "version", ""), "model": args.model, "memory_mode": args.memory_mode,
            "repeats": args.repeats, "seed": seed, "timeout": args.timeout, "jobs": args.jobs, "tasks": [t["id"] for t in tasks],
            "llm_brain_archive_sha256": str(install["archive_sha256"]), "started": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
            "codex_home": args.codex_home, "dry_run": args.dry_run}
    if not (args.resume and (output / "meta.json").exists()):
        (output / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    else:
        meta = json.loads((output / "meta.json").read_text())
        seed = meta["seed"]
    plan = [{"task": t, "condition": c, "repeat": r, "run_id": f"{t['id']}--{c}--r{r}"} for t in tasks for c in CONDITIONS for r in range(1, args.repeats + 1)]
    random.Random(seed).shuffle(plan)
    done_ids = set()
    if results_path.exists():
        done_ids = {json.loads(line)["run_id"] for line in results_path.read_text().splitlines() if line.strip()}
    todo = [item for item in plan if item["run_id"] not in done_ids]
    (output / "plan.json").write_text(json.dumps([i["run_id"] for i in plan], indent=2) + "\n")
    print(f"real_eval: runner={runner.name} tasks={len(tasks)} runs={len(plan)} todo={len(todo)} seed={seed} output={output}", flush=True)
    try:
        if not args.dry_run and not args.skip_preflight:
            runner.preflight(scratch, min(args.timeout, 300))
        ctx = {"install": install, "scratch": scratch, "runner": runner, "output": output, "bundle": bundle, "timeout": args.timeout,
               "memory_mode": args.memory_mode, "dry_run": args.dry_run, "keep": args.keep_roots, "reference": args.runner == "reference"}
        lock = threading.Lock()
        finished = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            futures = [pool.submit(one_run, item, ctx) for item in todo]
            for future in concurrent.futures.as_completed(futures):
                row = future.result()
                with lock:
                    finished += 1
                    if not args.dry_run:
                        with results_path.open("a", encoding="utf-8") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")
                    status = "DRY" if args.dry_run else ("PASS" if row.get("passed") else ("ERROR" if row.get("error") else "fail"))
                    print(f"[{finished}/{len(todo)}] {status:5} {row['run_id']} ({row['elapsed_seconds']}s)" + (f" {row['error']}" if row.get("error") else ""), flush=True)
    finally:
        runner.cleanup()
    if args.dry_run:
        print(f"real_eval: dry run complete; prompts and commands in {output / 'runs'}")
        return 0
    rows = [json.loads(line) for line in results_path.read_text().splitlines() if line.strip()]
    summary, markdown = summarise(rows, tasks, meta)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (output / "summary.md").write_text(markdown)
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
