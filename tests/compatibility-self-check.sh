#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-compatibility.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'compatibility self-check: %s\n' "$*" >&2; exit 1; }
project_id="proj_compatibility_self_check"
workspace="$fixture/workspace"
vault="$fixture/vault"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"

cat >"$project/okf/claims/legacy-contract.md" <<'EOF'
---
type: Claim
title: Legacy retrieval contract
status: stable
brain_project_id: proj_compatibility_self_check
brain_claim_id: legacy-contract
brain_review_state: approved
brain_sensitivity: internal
brain_source_authority: repository
brain_state_key: compatibility.current
brain_valid_from: "2020-01-01T00:00:00Z"
brain_valid_to: "2099-01-01T00:00:00Z"
brain_schema_version: 3
---
# Legacy retrieval contract

The default retrieval path remains compatible.
EOF

default_metadata="$fixture/default.metadata"
legacy_metadata="$fixture/legacy.metadata"
current_metadata="$fixture/current.metadata"
default_output="$("$cli" --root "$vault" search "$project_id" 'default retrieval path remains compatible' --metadata-file "$default_metadata" --limit 5)"
legacy_output="$("$cli" --root "$vault" search "$project_id" 'default retrieval path remains compatible' --intent legacy --metadata-file "$legacy_metadata" --limit 5)"
current_output="$("$cli" --root "$vault" search "$project_id" 'default retrieval path remains compatible' --intent current_state --metadata-file "$current_metadata" --limit 5)"
grep -Fq 'okf/claims/legacy-contract.md' <<<"$default_output" || fail 'default search lost the canonical result'
grep -Fqx 'intent=legacy' "$default_metadata" || fail 'default search intent changed'
grep -Fqx 'state_resolution=disabled' "$default_metadata" || fail 'default search enabled state resolution'
grep -Fqx 'intent=legacy' "$legacy_metadata" || fail 'explicit legacy search changed'
grep -Fqx 'state_resolution=disabled' "$legacy_metadata" || fail 'explicit legacy search enabled state resolution'
grep -Fqx 'intent=current_state' "$current_metadata" || fail 'current-state intent was not recorded'
grep -Fqx 'state_resolution=enabled' "$current_metadata" || fail 'current-state resolution was not enabled explicitly'
if grep -Fq 'State Warnings' <<<"$default_output"; then fail 'default search exposed current-state warnings'; fi

printf '%s\n' 'legacy compatibility query' >"$fixture/query.txt"
bridge="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --strategy lexical)"
printf '%s\n' "$bridge" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
required = {
    "status", "project_id", "requested_strategy", "actual_strategy", "degraded",
    "temporal", "evidence_refs", "resolution_mode", "conflicts", "results",
    "context_markdown",
}
missing = required.difference(payload)
assert not missing, missing
assert payload["state"] == "complete"
assert payload["complete"] is True and payload["partial"] is False and payload["failed"] is False
assert payload["warnings"] == [] and payload["actions"] == []
assert payload["retrieval"]["state"] == "complete"
assert payload["budget"]["requested_tokens"] == 4000
assert payload["truncation"]["truncated"] is False
assert payload["state_resolution"] == "disabled"
assert payload["results"]
result_required = {
    "path", "score", "type", "state", "status", "trust", "freshness",
    "sensitivity", "title",
}
assert result_required.issubset(payload["results"][0]), payload["results"][0]
# A pre-v0.6 consumer can select its old contract and ignore additive fields.
legacy_view = {key: payload[key] for key in required}
legacy_view["results"] = [
    {key: row[key] for key in result_required} for row in payload["results"]
]
assert legacy_view["results"]
'

legacy_project_id="proj_legacy_capture_compat"
legacy_project="$vault/projects/$legacy_project_id"
mkdir -p "$legacy_project/okf" "$legacy_project/episodes" "$legacy_project/concepts" "$legacy_project/claims" "$legacy_project/review"
: >"$legacy_project/audit.log"
printf '%s\n' '# Legacy index' >"$legacy_project/okf/index.md"
cat >"$fixture/legacy-source.md" <<'EOF'
# Legacy capture source

This compatibility command remains capture-only.
EOF
ingest_output="$("$cli" --root "$vault" ingest-source "$legacy_project_id" "$fixture/legacy-source.md")"
grep -Fq 'ingest-source=ok' <<<"$ingest_output" || fail 'legacy ingest-source command failed'
[ ! -f "$legacy_project/schema.version" ] || fail 'legacy ingest-source changed the storage schema'
[ ! -f "$legacy_project/okf/project.md" ] || fail 'legacy ingest-source changed canonical memory'

mkdir -p "$project/okf/procedures"
cat >"$project/okf/procedures/capsule-free.md" <<'EOF'
---
type: Procedure
title: Capsule-free compatibility procedure
status: stable
brain_project_id: proj_compatibility_self_check
brain_procedure_id: capsule-free
brain_review_state: approved
brain_sensitivity: internal
brain_source_authority: repository
brain_valid_from: "2020-01-01T00:00:00Z"
brain_valid_to: "2099-01-01T00:00:00Z"
brain_schema_version: 3
---
# Capsule-free compatibility procedure

Run the existing procedure path.
EOF
run_output="$("$cli" --root "$vault" run start "$project_id" okf/procedures/capsule-free.md --task 'legacy run' --request-id compatibility-run-1)"
grep -Fq 'run=ok' <<<"$run_output" || fail 'capsule-free run did not start'
run_id="$(printf '%s\n' "$run_output" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
[ -n "$run_id" ] || fail 'capsule-free run did not return an id'
[ -f "$project/runs/$run_id.md" ] || fail 'capsule-free run record missing'

printf '%s\n' 'llm-brain compatibility self-check passed'
