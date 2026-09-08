#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-core-contract.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'core contract self-check: %s\n' "$*" >&2; exit 1; }
assert_json() {
  local payload="$1" expression="$2"
  printf '%s\n' "$payload" | python3 -c "import json,sys; value=json.load(sys.stdin); assert $expression"
}

workspace="$fixture/workspace"
vault="$fixture/vault"
mkdir -p "$workspace"
git -C "$workspace" init -q
project_id=proj_core_contract
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims"
cat >"$project/okf/claims/contract.md" <<'EOF'
---
type: Claim
title: Core contract health record
status: stable
brain_project_id: proj_core_contract
brain_claim_id: contract
brain_review_state: approved
brain_sensitivity: internal
brain_source_authority: repository
brain_schema_version: 3
---
# Core contract health record

The bounded index contract is current.
EOF

missing_json="$($cli --root "$vault" index status "$project_id" --json)"
assert_json "$missing_json" 'value["health"] == "missing" and value["watcher"] == "none" and value["evidence_health"] == "missing"'

"$cli" --root "$vault" index build "$project_id" >/dev/null
current_json="$($cli --root "$vault" index status "$project_id" --json)"
assert_json "$current_json" 'value["health"] == "current" and value["watcher"] == "none" and value["generation"] and value["evidence_health"] == "missing" and value["evidence_watcher"] == "none"'

printf '\nChanged after publication.\n' >>"$project/okf/claims/contract.md"
stale_json="$($cli --root "$vault" index status "$project_id" --json)"
assert_json "$stale_json" 'value["health"] == "stale" and value["health_reason"] == "index-manifest-or-generation-stale"'

python3 - "$project/indexes/rebuild-state.json" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({"state": "building", "status": "building", "phase": "building"}) + "\n", encoding="utf-8")
PY
pending_json="$($cli --root "$vault" index status "$project_id" --json)"
assert_json "$pending_json" 'value["health"] == "rebuild-pending" and value["watcher"] == "none"'

evidence_index="$project/indexes/evidence-vectors.tsv"
printf 'path\thash\tview_version\tview_hash\tview_path\tmodel\tdimensions\tprincipal\tobserved_at\ttitle\tvector\tclaims_version\n' >"$evidence_index"
evidence_generation="evidence_$(shasum -a 256 "$evidence_index" | awk '{print substr($1,1,16)}')"
printf '%s\n' "$evidence_generation" >"$project/indexes/evidence-current"
python3 - "$project/indexes/evidence-rebuild-state.json" "$evidence_generation" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({"state": "idle", "status": "ready", "phase": "complete", "generation": sys.argv[2]}) + "\n", encoding="utf-8")
PY
evidence_json="$($cli --root "$vault" index status "$project_id" --json)"
assert_json "$evidence_json" 'value["evidence_health"] == "current" and value["evidence_generation"] == "'"$evidence_generation"'"'

cases="$fixture/cases.json"
cat >"$cases" <<'EOF'
{
  "format": "llm-brain.lifecycle-evaluation",
  "version": 1,
  "horizons": [1],
  "scenario_families": [
    {
      "id": "evalcontract",
      "description": "Evaluation metadata contract",
      "ground_truth": {
        "records": [],
        "queries": [{"id": "empty", "text": "no durable evidence", "expected_paths": []}]
      },
      "events": []
    }
  ]
}
EOF
eval_output="$fixture/evaluation"
python3 "$repo_root/scripts/eval-lifecycle.py" \
  --cases "$cases" --output "$eval_output" --repeats 1 \
  --provider fixture-provider --provider-version 1.2.3 --provider-commit deadbeef \
  --model fixture-model --dimensions 3 --build-status build --warm-cold cold \
  --availability degraded --degraded-path semantic-unavailable >/dev/null

python3 - "$eval_output" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
identity = json.loads((root / "run.json").read_text(encoding="utf-8"))
assert identity["provider"] == "fixture-provider"
assert identity["model"] == "fixture-model"
assert identity["dimensions"] == "3"
assert identity["build_status"] == "build"
assert identity["warm_cold"] == "cold"
assert identity["availability"] == "degraded"
assert identity["degraded_path"] == "semantic-unavailable"
trace = json.loads((root / "trace.jsonl").read_text(encoding="utf-8").splitlines()[0])
assert trace["provider"] == identity["provider"]
assert trace["dimensions"] == identity["dimensions"]
assert "Warm/cold state: `cold`" in (root / "report.md").read_text(encoding="utf-8")
PY

printf 'core contract self-check: ok\n'
