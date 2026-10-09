#!/usr/bin/env python3
"""Scripted reference agent used to verify the real-eval wiring.

It behaves like an ideal agent that follows the memory instructions: when
`llm-brain` is on PATH (memory on) it runs the brief, a context pack for the
task text and a few searches, and applies the correct solution only if the
retrieved text contains every knowledge marker the task needs.  Otherwise it
applies the plausible naive solution.  Retrieving a superseded or retracted
marker is a failure (exit 3).  It prints codex-style JSON command events so
the harness's accounting is exercised too.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


def event(command, code):
    print(json.dumps({"type": "item.completed", "item": {"type": "command_execution", "command": command, "exit_code": code}}), flush=True)


def llm_brain(*args):
    done = subprocess.run(["llm-brain", *args], capture_output=True, text=True)
    event("llm-brain " + " ".join(args), done.returncode)
    if done.returncode != 0:
        print(f"llm-brain {args[0]} failed: {done.stderr.strip()}", file=sys.stderr)
    text = done.stdout
    match = re.search(r"file=(\S+)", text)
    if args[0] == "pack" and match and Path(match.group(1)).is_file():
        text += Path(match.group(1)).read_text(encoding="utf-8")
    return text


def main():
    spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    task, condition = spec["task"], spec["condition"]
    ref = task["reference"]
    retrieved = ""
    if shutil.which("llm-brain"):
        pid = task["project_id"]
        retrieved += llm_brain("brief", pid)
        pack_args = ["pack", "build", pid, "--task", task.get("prompt") or task["question"]]
        for path in ref.get("paths", []):
            pack_args += ["--path", path]
        retrieved += llm_brain(*pack_args)
        for query in ref.get("queries", []):
            retrieved += llm_brain("search", pid, query)
    leaked = [m for m in ref.get("must_not_retrieve", []) if m in retrieved]
    if leaked:
        print(f"LEAK: superseded/retracted memory surfaced: {leaked}", file=sys.stderr)
        return 3
    informed = condition == "on" and all(marker in retrieved for marker in ref["needs"])
    if condition == "on" and not informed and task["kind"] == "memory":
        missing = [m for m in ref["needs"] if m not in retrieved]
        print(f"MISSING: memory markers not retrieved: {missing}", file=sys.stderr)
    good = informed or task["kind"] != "memory"
    if task["family"] == "coding":
        files = ref["solution"] if good or "naive" not in ref else ref["naive"]
        for rel, content in files.items():
            Path(rel).parent.mkdir(parents=True, exist_ok=True)
            Path(rel).write_text(content, encoding="utf-8")
    else:
        answer = ref["answer_on"] if good else ref["answer_off"]
        Path("answer.json").write_text(json.dumps(answer, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
