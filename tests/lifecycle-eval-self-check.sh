#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
evaluator="$repo_root/scripts/eval-lifecycle.py"
fixture="$repo_root/tests/fixtures/lifecycle/cases.v1.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-lifecycle-self-check.XXXXXX")"
cleanup() {
  if [ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ]; then
    printf 'lifecycle-eval-artifacts=%s\n' "$tmp" >&2
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

fail() { printf 'lifecycle evaluation self-check: %s\n' "$*" >&2; exit 1; }

python3 -m py_compile "$evaluator" || fail 'evaluator is not parseable'
bash -n "$repo_root/bin/llm-brain" || fail 'reference CLI is not parseable'

# Short smoke: one family, one checkpoint and all retrieval modes.
python3 - "$fixture" "$tmp/short-cases.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1], encoding="utf-8"))
source["horizons"] = [3]
source["scenario_families"] = [source["scenario_families"][0]]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(source, stream)
PY
python3 "$evaluator" --cases "$tmp/short-cases.json" --output "$tmp/short" --seed 0 --repeats 1 >/dev/null
python3 - "$tmp/short/summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(summary["modes"]) == {"none", "raw-source", "factual", "explicit", "evidence", "historical"}
assert summary["actual_write_cost"] > 0
assert summary["operation_counts"]["capture"] == 1
assert summary["checkpoint_rows"] == 12
assert summary["horizon_endpoint_rows"] == 6
assert summary["modes"]["raw-source"]["gold_hit_rate"] == 1.0
assert summary["modes"]["factual"]["checkpoint_evaluated"]
assert summary["modes"]["factual"]["model_accuracy"] == "unmeasured"
PY

# Existing-output identity mismatch must fail closed rather than overwrite.
if python3 "$evaluator" --cases "$tmp/short-cases.json" --output "$tmp/short" --seed 1 --repeats 1 >/dev/null 2>&1; then
  fail 'mismatched output identity was accepted'
fi

# Full fixture smoke: all twelve families at both requested horizons.  The
# default is one deterministic repetition to keep this self-check bounded;
# set LIFECYCLE_FULL_REPEATS=5 for the acceptance run.
full_repeats="${LIFECYCLE_FULL_REPEATS:-1}"
python3 "$evaluator" --cases "$fixture" --output "$tmp/full" --seed 0 --repeats "$full_repeats" >/dev/null
python3 - "$tmp/full/summary.json" "$full_repeats" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
repeats = int(sys.argv[2])
for mode, metric in summary["modes"].items():
    assert metric["traces"] == 48 * repeats, (mode, metric["traces"])
    assert metric["checkpoint_evaluated"]
assert summary["operation_counts"]["capture"] >= 24
assert summary["operation_counts"]["retrieval"] >= 24
assert summary["actual_write_cost"] > 0
assert summary["repetition_semantics"].startswith("deterministic")
assert summary["model_accuracy_note"].startswith("host-scored")
PY

# Metric controls: source presence without a host-side source event mapping
# must not become a false green, and answer-runner self-report is not accuracy.
cat >"$tmp/negative-cases.json" <<'JSON'
{
  "format": "llm-brain.lifecycle-evaluation",
  "version": 1,
  "horizons": [2],
  "scenario_families": [{
    "id": "negative-control",
    "description": "Metric controls",
    "ground_truth": {
      "records": [{"id": "negative-fact", "title": "Negative fact", "text": "The exact fixture answer."}],
      "queries": [{
        "id": "negative-query",
        "text": "negative fixture answer",
        "expected_paths": ["negative-fact"],
        "source_expected": true,
        "future_paths": ["okf/claims/future-secret.md"],
        "expected_answer": "The exact fixture answer."
      }]
    },
    "events": [
      {"operation": "capture", "id": "negative-observation", "text": "Negative fixture answer is present in source custody."},
      {"operation": "retrieval", "query_id": "negative-query"}
    ]
  }]
}
JSON
cat >"$tmp/answer-runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
request = json.load(open(sys.argv[1], encoding="utf-8"))
text = json.dumps(request)
assert "expected_paths" not in request
assert "future_paths" not in request
assert "future-secret" not in text
assert not any("cases" in path.name for path in pathlib.Path.cwd().iterdir())
json.dump({"outcome": "pass", "answer": "Wrong answer", "tokens": 7}, open(sys.argv[2], "w", encoding="utf-8"))
PY
RUNNER
chmod 755 "$tmp/answer-runner.sh"
python3 "$evaluator" --cases "$tmp/negative-cases.json" --output "$tmp/negative" --seed 0 --repeats 2 --answer-runner "$tmp/answer-runner.sh" >/dev/null
python3 - "$tmp/negative/summary.json" "$tmp/negative/trace.jsonl" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8")]
raw = [row for row in rows if row["mode"] == "raw-source"]
assert raw and raw[0]["candidate_paths"] and not raw[0]["gold_hit"]
assert summary["modes"]["factual"]["model_accuracy"] == 0.0
assert summary["modes"]["factual"]["model_pass_at_repeats"] == 0.0
assert summary["modes"]["factual"]["answer_outcomes"] == {"pass": 4}
PY

printf '%s\n' 'llm-brain lifecycle evaluation self-check passed'
