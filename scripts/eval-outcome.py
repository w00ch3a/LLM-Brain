#!/usr/bin/env python3
"""Outcome evaluation: small coding tasks with and without LLM-Brain.

Each task is materialised twice in a disposable workspace.  In ``off`` mode
the runner receives only the task; in ``on`` mode it also receives a context
pack built from a disposable vault seeded with the task's approved memory.
Success is decided only by the task's executable test command, never by the
runner's self-report.  Output is a derived report directory; nothing here
touches a real vault.

The runner is a trusted local executable invoked as
``RUNNER request.json output.json``.  request.json carries ``task``,
``workdir``, ``mode`` and ``context_path`` (null when memory is off).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

FORMAT = "llm-brain.outcome-evaluation"
VERSION = 1
MODES = ("off", "on")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
REL_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./-]{0,127}$")
ALLOWED_TEST_PROGRAMS = {"python3", "sh", "bash"}
MAX_TASKS = 64
MAX_FILE_BYTES = 256 * 1024
REPO_ROOT = Path(__file__).resolve().parent.parent


class CaseError(Exception):
    pass


def yaml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def validate(cases: dict[str, Any]) -> list[dict[str, Any]]:
    if cases.get("format") != FORMAT or cases.get("version") != VERSION:
        raise CaseError("unsupported case format or version")
    tasks = cases.get("tasks")
    if not isinstance(tasks, list) or not tasks or len(tasks) > MAX_TASKS:
        raise CaseError("tasks must be a non-empty list")
    seen: set[str] = set()
    for task in tasks:
        task_id = task.get("id")
        if not isinstance(task_id, str) or not ID_RE.match(task_id) or task_id in seen:
            raise CaseError(f"invalid or duplicate task id: {task_id!r}")
        seen.add(task_id)
        if not isinstance(task.get("task"), str) or not task["task"].strip() or "\n" in task["task"]:
            raise CaseError(f"{task_id}: task must be one non-empty line")
        files = task.get("files")
        if not isinstance(files, dict) or not files:
            raise CaseError(f"{task_id}: files must be a non-empty object")
        for rel, content in files.items():
            if not REL_RE.match(rel) or ".." in rel.split("/") or not isinstance(content, str) or len(content.encode("utf-8")) > MAX_FILE_BYTES:
                raise CaseError(f"{task_id}: invalid file {rel!r}")
        memory = task.get("memory", [])
        if not isinstance(memory, list):
            raise CaseError(f"{task_id}: memory must be a list")
        for record in memory:
            if not isinstance(record, dict) or not ID_RE.match(str(record.get("id", ""))):
                raise CaseError(f"{task_id}: invalid memory id")
            for key in ("title", "text"):
                if not isinstance(record.get(key), str) or not record[key].strip() or "\n" in record[key]:
                    raise CaseError(f"{task_id}: memory {key} must be one non-empty line")
            for path in record.get("paths", []):
                if not isinstance(path, str) or not REL_RE.match(path.replace("*", "x")):
                    raise CaseError(f"{task_id}: invalid memory path glob")
        test = task.get("test")
        if not isinstance(test, list) or not test or not all(isinstance(part, str) for part in test) or test[0] not in ALLOWED_TEST_PROGRAMS:
            raise CaseError(f"{task_id}: test must be an argv list starting with one of {sorted(ALLOWED_TEST_PROGRAMS)}")
    return tasks


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def seed_vault(cli: Path, vault: Path, workdir: Path, project_id: str, task: dict[str, Any], env: dict[str, str]) -> None:
    completed = run([str(cli), "--root", str(vault), "project", "ensure", str(workdir), "--id", project_id], workdir, env, 60)
    if completed.returncode != 0:
        raise CaseError(f"project ensure failed: {completed.stderr.strip()}")
    claims = vault / "projects" / project_id / "okf" / "claims"
    for record in task.get("memory", []):
        lines = [
            "---",
            "type: Claim",
            f"title: {yaml_string(record['title'])}",
            "status: stable",
            'generated: {by: "human:outcome-eval", at: "2026-01-01T00:00:00Z"}',
            'sources: [{resource: "outcome evaluation fixture"}]',
            f"brain_project_id: {project_id}",
            "brain_review_state: approved",
            "brain_source_authority: human-directive",
            "brain_sensitivity: internal",
        ]
        if record.get("paths"):
            lines.append("brain_paths: [" + ", ".join(yaml_string(path) for path in record["paths"]) + "]")
        lines += ["brain_schema_version: 3", "---", f"# {record['title']}", "", record["text"], ""]
        (claims / f"{record['id']}.md").write_text("\n".join(lines), encoding="utf-8")


def build_pack(cli: Path, vault: Path, workdir: Path, project_id: str, task: dict[str, Any], env: dict[str, str], budget: int) -> tuple[Path, int]:
    command = [str(cli), "--root", str(vault), "pack", "build", project_id, "--task", task["task"], "--agent", "outcome-eval", "--budget-tokens", str(budget)]
    for rel in sorted(task["files"]):
        command += ["--path", rel]
    completed = run(command, workdir, env, 120)
    if completed.returncode != 0:
        raise CaseError(f"pack build failed: {completed.stderr.strip()}")
    fields = dict(part.split("=", 1) for part in completed.stdout.split() if "=" in part)
    pack = Path(fields["file"])
    return pack, pack.stat().st_size


def main() -> int:
    parser = argparse.ArgumentParser(description="Run small coding tasks with and without LLM-Brain, scored by executable tests")
    parser.add_argument("--cases", required=True)
    parser.add_argument("--output", required=True, help="new output directory; existing paths are rejected")
    parser.add_argument("--runner", default=str(REPO_ROOT / "scripts" / "outcome-reference-runner.py"))
    parser.add_argument("--cli", default=str(REPO_ROOT / "bin" / "llm-brain"))
    parser.add_argument("--budget-tokens", type=int, default=1200)
    parser.add_argument("--runner-timeout", type=int, default=600)
    parser.add_argument("--test-timeout", type=int, default=120)
    parser.add_argument("--keep-workspaces", action="store_true")
    args = parser.parse_args()

    output = Path(args.output)
    if output.exists():
        print("outcome_eval=failed reason=output-exists", file=sys.stderr)
        return 65
    cases_path = Path(args.cases)
    try:
        cases = json.loads(cases_path.read_text(encoding="utf-8"))
        tasks = validate(cases)
    except (OSError, json.JSONDecodeError, CaseError) as error:
        print(f"outcome_eval=failed reason={error}", file=sys.stderr)
        return 65
    runner = Path(args.runner).resolve()
    cli = Path(args.cli).resolve()
    output.mkdir(parents=True)
    scratch = Path(tempfile.mkdtemp(prefix="llm-brain-outcome."))
    env = {key: value for key, value in os.environ.items() if not key.startswith("LLM_BRAIN_")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    rows: list[dict[str, Any]] = []
    try:
        for index, task in enumerate(tasks):
            for mode in MODES:
                base = scratch / f"{index:03d}-{task['id']}-{mode}"
                workdir = base / "workspace"
                workdir.mkdir(parents=True)
                for rel, content in task["files"].items():
                    target = workdir / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(content, encoding="utf-8")
                row: dict[str, Any] = {"task_id": task["id"], "mode": mode, "memory_records": len(task.get("memory", []))}
                started = time.monotonic()
                context_path = None
                try:
                    if mode == "on":
                        project_id = f"proj_outcome_{index:03d}"
                        seed_vault(cli, base / "vault", workdir, project_id, task, env)
                        pack, size = build_pack(cli, base / "vault", workdir, project_id, task, env, args.budget_tokens)
                        context_path = str(base / "context.md")
                        shutil.copyfile(pack, context_path)
                        row["context_bytes"] = size
                    else:
                        row["context_bytes"] = 0
                    request = base / "request.json"
                    request.write_text(json.dumps({"task": task["task"], "workdir": str(workdir), "mode": mode, "context_path": context_path}) + "\n", encoding="utf-8")
                    runner_result = run([str(runner), str(request), str(base / "runner-output.json")], workdir, env, args.runner_timeout)
                    row["runner_exit"] = runner_result.returncode
                    test = run(task["test"], workdir, env, args.test_timeout)
                    row["test_exit"] = test.returncode
                    row["passed"] = test.returncode == 0
                    row["error"] = None
                except (CaseError, subprocess.TimeoutExpired, OSError) as error:
                    row["passed"] = False
                    row["error"] = str(error)[:500]
                row["elapsed_ms"] = int((time.monotonic() - started) * 1000)
                rows.append(row)
    finally:
        if not args.keep_workspaces:
            shutil.rmtree(scratch, ignore_errors=True)

    summary: dict[str, Any] = {
        "format": FORMAT,
        "version": VERSION,
        "derived": True,
        "cases_sha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
        "runner_sha256": hashlib.sha256(runner.read_bytes()).hexdigest(),
        "tasks": len(tasks),
        "modes": {},
        "scoring": "executable-tests-only",
    }
    for mode in MODES:
        mode_rows = [row for row in rows if row["mode"] == mode]
        passed = sum(1 for row in mode_rows if row["passed"])
        summary["modes"][mode] = {
            "passed": passed,
            "total": len(mode_rows),
            "pass_rate": round(passed / len(mode_rows), 4) if mode_rows else 0.0,
            "errors": sum(1 for row in mode_rows if row["error"]),
            "mean_context_bytes": round(sum(row["context_bytes"] for row in mode_rows if "context_bytes" in row) / len(mode_rows), 1) if mode_rows else 0.0,
        }
    summary["uplift"] = round(summary["modes"]["on"]["pass_rate"] - summary["modes"]["off"]["pass_rate"], 4)
    summary["regressions"] = sorted(
        task["id"] for task in tasks
        if any(r["passed"] for r in rows if r["task_id"] == task["id"] and r["mode"] == "off")
        and not any(r["passed"] for r in rows if r["task_id"] == task["id"] and r["mode"] == "on")
    )
    with (output / "results.jsonl").open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"outcome_eval=ok tasks={len(tasks)} off={summary['modes']['off']['passed']}/{len(tasks)} on={summary['modes']['on']['passed']}/{len(tasks)} uplift={summary['uplift']} output={output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
