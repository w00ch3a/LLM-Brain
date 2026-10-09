#!/usr/bin/env bash
# Real-eval harness self-check: the scripted reference agent must show the
# full memory effect (fair off/on trees, retrieval through the real CLI,
# superseded/retracted memory hidden), and the codex adapter must isolate the
# agent (sandbox flags, private HOME/PATH/CODEX_HOME) - exercised with a fake codex.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-real-eval.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'real-eval self-check: %s\n' "$*" >&2; exit 1; }

version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
archive="$repo_root/dist/llm-brain-${version}-standalone.tar.gz"
[ -f "$archive" ] || bash "$repo_root/scripts/package-ai-skill.sh" >/dev/null
bundle="$fixture/bundle"
mkdir -p "$bundle/dist" "$bundle/vendor" "$bundle/tasks"
cp "$repo_root"/evals/real/{run.sh,eval_real.py,reference_agent.py} "$bundle/"
cp "$repo_root"/evals/real/tasks/{coding.py,research.py} "$bundle/tasks/"
cp "$archive" "$archive.sha256" "$bundle/dist/"
yaml_dir="$(python3 -c 'import os, yaml; print(os.path.dirname(yaml.__file__))')"
mkdir "$bundle/vendor/yaml" && cp "$yaml_dir"/*.py "$bundle/vendor/yaml/"
export PYTHONDONTWRITEBYTECODE=1

# 1. Reference agent over the whole suite.
"$bundle/run.sh" "$fixture/ref" --runner reference --repeats 1 --jobs 4 --seed 3 --scratch "$fixture/scratch" >"$fixture/ref.log" 2>&1 || { cat "$fixture/ref.log" >&2; fail 'reference run failed'; }
python3 - "$fixture/ref/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for family in ("coding", "research"):
    m, c = s["families"][family]["memory"], s["families"][family]["controls"]
    assert (m["on"], m["off"]) == (1.0, 0.0), (family, m)
    assert (c["on"], c["off"]) == (1.0, 1.0), (family, c)
    assert m["tasks"] == 10 and c["tasks"] == 2, (family, m, c)
assert not s["errors"] and not s["contamination_flagged_runs"] and not s["unequal_work_trees"], s
assert s["memory_use"]["runs_using_llm_brain"] == s["memory_use"]["on_runs"] == 24, s["memory_use"]
assert s["memory_use"]["failed_llm_brain_calls"] == 0, s["memory_use"]
PY
! grep -Rqs -E 'LEAK|MISSING' "$fixture/ref/runs" || fail 'reference agent saw leaked or missing memory'
[ -z "$(ls -A "$fixture/scratch")" ] || fail 'per-run roots were not cleaned up'

# 2. Codex adapter with a fake codex: isolation and accounting.
fake_home="$fixture/fakehome"
mkdir -p "$fake_home/.codex" "$fake_home/.local/bin"
printf '{"fake": true}\n' >"$fake_home/.codex/auth.json"
printf '#!/bin/sh\necho real-brain-must-not-be-used\n' >"$fake_home/.local/bin/llm-brain"; chmod +x "$fake_home/.local/bin/llm-brain"
export FAKE_CODEX_LOG="$fixture/fake-codex.jsonl"
HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" "$bundle/run.sh" "$fixture/codex" --smoke --codex "$repo_root/tests/fixtures/real-eval/fake-codex" --codex-config "fake.log=$FAKE_CODEX_LOG" \
  --model test-model --seed 5 >"$fixture/codex.log" 2>&1 || { cat "$fixture/codex.log" >&2; fail 'fake codex smoke failed'; }
python3 - "$FAKE_CODEX_LOG" "$fixture/codex" "$fake_home" <<'PY'
import json, sys
from pathlib import Path
records = [json.loads(line) for line in open(sys.argv[1])]
out, fake_home = Path(sys.argv[2]), sys.argv[3]
assert len(records) == 5, len(records)  # preflight + 2 tasks x 2 conditions
for r in records:
    argv = r["argv"]
    assert argv[argv.index("--sandbox") + 1] == "workspace-write", argv
    assert "sandbox_workspace_write.network_access=false" in argv and any(a.startswith("sandbox_workspace_write.writable_roots=") for a in argv), argv
    assert argv[argv.index("-m") + 1] == "test-model"
    assert r["auth_present"] and r["env"]["CODEX_HOME"].startswith(str(out)), r
    assert fake_home not in r["env"]["PATH"] and not r["env"]["HOME"].startswith(fake_home), r["env"]
    assert r["cwd"] == r["cd"] and r["cd"].endswith("/work"), r
    if r["env"]["LLM_BRAIN_ROOT"]:
        assert r["llm_brain_on_path"] and r["llm_brain_on_path"].startswith(r["env"]["HOME"].rsplit("/home", 1)[0]), r
    else:
        assert r["llm_brain_on_path"] is None, r
assert sum(1 for r in records if r["env"]["LLM_BRAIN_ROOT"]) == 2
rows = [json.loads(line) for line in open(out / "results.jsonl")]
assert len(rows) == 4 and all(r["usage"] == {"input_tokens": 1000, "cached_input_tokens": 200, "output_tokens": 50} for r in rows), rows
assert all(r["memory_commands"] == (1 if r["condition"] == "on" else 0) for r in rows), rows
assert all(r["memory_calls_logged"] == (1 if r["condition"] == "on" else 0) for r in rows), rows
assert not (out / ".codex-home").exists(), "isolated CODEX_HOME was not removed"
assert all(not r["passed"] for r in rows)  # the fake agent solves nothing
summary = (out / "summary.md").read_text()
assert "Mean input tokens" in summary and "| on | " in summary
PY

# 3. Dry run: every run prepared, no agent invoked.
: >"$FAKE_CODEX_LOG"
HOME="$fake_home" "$bundle/run.sh" "$fixture/dry" --dry-run --repeats 1 --codex "$repo_root/tests/fixtures/real-eval/fake-codex" --codex-config "fake.log=$FAKE_CODEX_LOG" >"$fixture/dry.log" 2>&1 || { cat "$fixture/dry.log" >&2; fail 'dry run failed'; }
[ "$(find "$fixture/dry/runs" -name command.txt | wc -l | tr -d ' ')" = 48 ] || fail 'dry run did not prepare 48 runs'
[ ! -s "$FAKE_CODEX_LOG" ] || fail 'dry run invoked the agent'
grep -Fq 'llm-brain brief proj_shop' "$fixture/dry/runs/c01-receipt-price-format--on--r1/prompt.txt" || fail 'memory-on prompt lacks instructions'
! grep -Fq 'llm-brain' "$fixture/dry/runs/c01-receipt-price-format--off--r1/prompt.txt" || fail 'memory-off prompt mentions llm-brain'

printf '%s\n' 'llm-brain real-eval self-check passed'
