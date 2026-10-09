#!/usr/bin/env python3
"""Deterministic reference runner for scripts/eval-outcome.py.

It is not an agent.  It applies only edits stated in the task text or in the
LLM-Brain context, in the fixed form "In FILE the NAME constant must be VALUE",
so the harness can prove that it measures memory-on versus memory-off outcome
differences with executable tests.  Real agents plug in through --runner.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
DIRECTIVE = re.compile(r"In ([A-Za-z0-9_./-]+\.py) the ([A-Z][A-Z0-9_]*) constant must be (\"[^\"\n]*\"|True|False|-?[0-9]+)")


def main() -> int:
    request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    workdir = Path(request["workdir"])
    text = request["task"]
    context_path = request.get("context_path")
    if context_path:
        text += "\n" + Path(context_path).read_text(encoding="utf-8")
    applied = 0
    for relative, name, value in DIRECTIVE.findall(text):
        target = (workdir / relative).resolve()
        if workdir.resolve() not in target.parents or not target.is_file():
            continue
        source = target.read_text(encoding="utf-8")
        updated, count = re.subn(rf"^{name}\s*=.*$", f"{name} = {value}", source, flags=re.MULTILINE)
        if count:
            target.write_text(updated, encoding="utf-8")
            applied += count
    Path(sys.argv[2]).write_text(json.dumps({"edits": applied}) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
