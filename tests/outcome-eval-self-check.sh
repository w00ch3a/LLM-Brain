#!/usr/bin/env bash
# Outcome harness: small coding tasks with vs without LLM-Brain, scored only by
# executable tests.  The deterministic reference runner proves the harness
# measures memory-dependent outcomes; real agents plug in with --runner.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
evaluator="$repo_root/scripts/eval-outcome.py"
fixture="$repo_root/tests/fixtures/outcome/tasks.v1.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-outcome-self-check.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'outcome evaluation self-check: %s\n' "$*" >&2; exit 1; }

python3 -m py_compile "$evaluator" "$repo_root/scripts/outcome-reference-runner.py" || fail 'harness is not parseable'
python3 "$evaluator" --cases "$fixture" --output "$tmp/run" >/dev/null
python3 - "$tmp/run/summary.json" "$tmp/run/results.jsonl" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8")]
assert summary["scoring"] == "executable-tests-only"
assert summary["modes"]["off"]["passed"] == 1, summary
assert summary["modes"]["on"]["passed"] == 4, summary
assert summary["uplift"] == 0.75
assert summary["regressions"] == []
assert all(row["error"] is None for row in rows), rows
assert all(row["context_bytes"] == 0 for row in rows if row["mode"] == "off")
PY

# Existing output is never overwritten.
if python3 "$evaluator" --cases "$fixture" --output "$tmp/run" >/dev/null 2>&1; then fail 'existing output accepted'; fi

# A runner that claims success but edits nothing scores zero: tests decide.
cat >"$tmp/liar.sh" <<'RUNNER'
#!/usr/bin/env bash
printf '{"outcome":"pass"}\n' >"$2"
RUNNER
chmod 755 "$tmp/liar.sh"
python3 "$evaluator" --cases "$fixture" --output "$tmp/liar" --runner "$tmp/liar.sh" >/dev/null
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["modes"]["on"]["passed"] == 0 and s["modes"]["off"]["passed"] == 0, s' "$tmp/liar/summary.json"

# Unsafe case files are rejected before anything runs.
python3 - "$fixture" "$tmp/unsafe.json" <<'PY'
import json, sys
cases = json.load(open(sys.argv[1], encoding="utf-8"))
cases["tasks"][0]["test"] = ["rm", "-rf", "/"]
json.dump(cases, open(sys.argv[2], "w", encoding="utf-8"))
PY
if python3 "$evaluator" --cases "$tmp/unsafe.json" --output "$tmp/unsafe" >/dev/null 2>&1; then fail 'unsafe test command accepted'; fi

printf '%s\n' 'llm-brain outcome evaluation self-check passed'
