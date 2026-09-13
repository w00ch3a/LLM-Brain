#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-maintenance.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_maintenance_self_check"
project="$vault/projects/$project_id"

fail() { printf 'maintenance self-check: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<<"$1" || fail "expected output to contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" <<<"$1" || fail "output unexpectedly contained: $2"; }

tree_hash() {
  python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    if path.is_file() and not path.is_symlink():
        rows.append(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes())
print(hashlib.sha256(b"\0".join(rows)).hexdigest())
PY
}

json_check() {
  local payload="$1" expression="$2"
  printf '%s\n' "$payload" | python3 -c "import json,sys; value=json.load(sys.stdin); assert $expression"
}

write_claim() {
  local file="$1" id="$2" title="$3" body="$4" extra="${5:-}" sensitivity="${6:-internal}"
  {
    printf '%s\n' '---' 'type: Claim' "title: $title" "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' "brain_sensitivity: $sensitivity" 'brain_source_authority: repository' 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' "$body"
  } >"$file"
}

write_request() {
  local file="$1" id="$2" state="$3" title="$4" episode="$5" extra="${6:-}"
  {
    printf '%s\n' '---' 'type: WorkRequest' "title: $title" "brain_project_id: $project_id" "brain_request_id: $id" "brain_request_state: $state" "brain_operation: reflect" "brain_episode_ref: $episode" 'brain_sensitivity: internal' 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' 'Synthetic maintenance work item.'
  } >"$file"
}

mkdir -p "$project/okf/claims" "$project/okf/retractions" "$project/sources" "$project/episodes" "$project/requests" "$project/audit" "$project/context-packs"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null

cat >"$project/sources/root-a.md" <<'EOF'
---
type: Source
title: Maintenance source A
brain_sensitivity: internal
brain_schema_version: 3
---
# Maintenance source A

Synthetic source A.
EOF
cat >"$project/sources/root-b.md" <<'EOF'
---
type: Source
title: Maintenance source B
brain_sensitivity: internal
brain_schema_version: 3
---
# Maintenance source B

Synthetic source B.
EOF
cat >"$project/episodes/recovered.md" <<'EOF'
---
type: Episode
title: Recovered maintenance episode
brain_episode_id: recovered-episode
brain_sensitivity: internal
brain_source_ref: sources/root-a.md
brain_schema_version: 3
---
# Recovered maintenance episode
EOF

write_claim "$project/okf/claims/current.md" current 'Current maintenance record' 'current maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_state_key: maintenance.current\nbrain_source_ref: sources/root-a.md\nbrain_last_verified_at: "2026-09-12T00:00:00Z"'
write_claim "$project/okf/claims/stale.md" stale 'Stale maintenance record' 'stale maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nstale_after: "2020-01-01"\nbrain_source_ref: sources/root-a.md'
write_claim "$project/okf/claims/expired.md" expired 'Expired maintenance record' 'expired maintenance marker' $'brain_valid_from: "2020-01-01T00:00:00Z"\nbrain_valid_to: "2020-02-01T00:00:00Z"\nbrain_source_ref: sources/root-b.md'
write_claim "$project/okf/claims/unknown.md" unknown 'Unknown validity maintenance record' 'unknown validity marker' 'brain_source_ref: sources/root-b.md'
write_claim "$project/okf/claims/unknown-provenance.md" unknown-provenance 'Unknown provenance maintenance record' 'unknown provenance marker'
write_claim "$project/okf/claims/conflict-a.md" conflict-a 'Conflicting maintenance record A' 'conflict maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_state_key: maintenance.conflict\nbrain_source_ref: sources/root-a.md'
write_claim "$project/okf/claims/conflict-b.md" conflict-b 'Conflicting maintenance record B' 'conflict maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_state_key: maintenance.conflict\nbrain_source_ref: sources/root-a.md'
write_claim "$project/okf/claims/missing-dependency.md" missing-dependency 'Missing dependency maintenance record' 'missing dependency marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_depends_on: missing-maintenance\nbrain_source_ref: sources/root-b.md'
write_claim "$project/okf/claims/inaccessible-dependency.md" inaccessible-dependency 'Inaccessible dependency maintenance record' 'inaccessible dependency marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_depends_on: hidden-maintenance\nbrain_source_ref: sources/root-b.md'
write_claim "$project/okf/claims/cycle-a.md" cycle-a 'Cyclic maintenance record A' 'cycle maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_depends_on: cycle-b\nbrain_source_ref: sources/root-a.md'
write_claim "$project/okf/claims/cycle-b.md" cycle-b 'Cyclic maintenance record B' 'cycle maintenance marker' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_depends_on: cycle-a\nbrain_source_ref: sources/root-a.md'
write_claim "$project/okf/claims/hidden-maintenance.md" hidden-maintenance 'UNLISTED-HIDDEN-MAINTENANCE-MARKER' 'UNLISTED-HIDDEN-MAINTENANCE-MARKER' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_state_key: maintenance.hidden\nbrain_source_ref: sources/root-a.md\nbrain_principal: alice' restricted
write_claim "$project/okf/claims/scoped-maintenance.md" scoped-maintenance 'UNLISTED-SCOPED-MAINTENANCE-MARKER' 'UNLISTED-SCOPED-MAINTENANCE-MARKER' $'brain_valid_from: "2026-01-01T00:00:00Z"\nbrain_valid_to: "2099-01-01T00:00:00Z"\nbrain_source_ref: sources/root-a.md\nbrain_principal: alice'

cat >"$project/okf/retractions/stale.md" <<'EOF'
---
type: Retraction
brain_project_id: proj_maintenance_self_check
brain_retracts: stale
brain_review_state: approved
brain_sensitivity: internal
brain_schema_version: 3
---
# Retraction
EOF
printf 'stale residual marker\n' >"$project/context-packs/residual.md"

write_request "$project/requests/pending.md" pending pending 'Pending maintenance work' episodes/recovered.md
write_request "$project/requests/recovered.md" recovered pending 'Recovered maintenance work' episodes/recovered.md 'brain_recovered_at: "2026-09-12T00:00:00Z"'
write_request "$project/requests/failed.md" failed failed 'Failed maintenance work' episodes/recovered.md 'brain_error: provider-timeout'
write_request "$project/requests/orphaned.md" orphaned abandoned 'Orphaned maintenance work' episodes/missing.md

cat >"$project/audit/retrieval-receipts.jsonl" <<'EOF'
{"schema":"llm-brain.retrieval-receipt.v1","receipt_id":"0123456789abcdef01234567","project_id":"proj_maintenance_self_check","selected":["okf/claims/current.md"]}
not-json
{"schema":"wrong-receipt-schema","receipt_id":"fedcba9876543210fedcba98","project_id":"proj_other","selected":[]}
EOF

# Build once, then make the canonical tree drift. Maintenance must report the
# stale/failed index and never repair it as a side effect.
"$cli" --root "$vault" index build "$project_id" >/dev/null
printf '%s\n' 'index drift marker' >>"$project/okf/claims/current.md"
cat >"$project/indexes/rebuild-state.json" <<'EOF'
{"state":"failed","status":"failed","phase":"failed","error":"synthetic maintenance failure"}
EOF

before_preview="$(tree_hash "$project")"
preview_json="$($cli --root "$vault" maintenance preview "$project_id" --principal bob --limit 200 --json)"
after_preview="$(tree_hash "$project")"
[ "$before_preview" = "$after_preview" ] || fail 'preview changed the project tree'
json_check "$preview_json" 'isinstance(value, dict) and value.get("maintenance_state") in {"healthy", "attention", "blocked"} and isinstance(value.get("counts"), dict) and isinstance(value.get("bounded_items"), list)'
json_check "$preview_json" 'value["report_state"] == "missing"'
json_check "$preview_json" 'all(value["counts"][key] >= 1 for key in ("expired_validity", "stale_verification", "unknown_validity", "unresolved_conflict", "unresolved_dependency", "unresolved_inaccessible", "invalid_cycle", "pending_work", "failed_work", "recovered_work", "orphaned_work", "receipt_issues", "index_issues", "provenance_issues", "retraction_residuals"))'
json_check "$preview_json" 'value["counts"]["independent_source_count"] >= 2 and value["counts"]["correlated_record_count"] >= 2'
json_check "$preview_json" '"UNLISTED-HIDDEN-MAINTENANCE-MARKER" not in json.dumps(value) and "UNLISTED-SCOPED-MAINTENANCE-MARKER" not in json.dumps(value)'

status_before="$($cli --root "$vault" maintenance status "$project_id" --principal bob --json)"
json_check "$status_before" 'set(("maintenance_state", "schedule_state", "report_state", "report_hash", "counts", "bounded_items", "recommendations", "reminder")) <= set(value)'
json_check "$status_before" 'value["report_state"] == "missing" and value["reminder"] == "run-or-schedule"'
if "$cli" --root "$vault" maintenance status "$project_id" --principal bob --strict >/dev/null 2>&1; then
  fail 'strict status accepted attention findings'
fi

canonical_before_run="$(tree_hash "$project/okf")"
run_output="$($cli --root "$vault" maintenance run "$project_id" --principal bob --limit 200)"
assert_contains "$run_output" 'maintenance=ok'
latest="$project/maintenance/latest.md"
[ -f "$latest" ] || fail 'maintenance run did not write latest.md'
grep -Fqx 'type: MaintenanceReport' <(sed -n '1,2p' "$latest") || fail 'latest report type missing'
grep -Fq 'brain_artifact_state: derived' "$latest" || fail 'latest report is not derived'
grep -Fq 'brain_schema_version: 3' "$latest" || fail 'latest report schema drifted'
grep -Fq 'not canonical memory' "$latest" || fail 'report does not warn that it is derived'
grep -Fq 'never deletes, retracts or promotes' "$latest" || fail 'report does not state safe non-mutating behaviour'
grep -Fqi 'retention' "$latest" || fail 'retention findings missing'
grep -Eqi 'review[- ]candidate|review candidates' "$latest" || fail 'retention review warning missing'
grep -Fq 'UNLISTED-HIDDEN-MAINTENANCE-MARKER' "$latest" && fail 'hidden title leaked into report' || true
grep -Fq 'UNLISTED-SCOPED-MAINTENANCE-MARKER' "$latest" && fail 'scoped title leaked into report' || true
[ "$(find "$project/maintenance" -maxdepth 1 -type f -name 'latest.md' | wc -l | tr -d ' ')" = 1 ] || fail 'unexpected maintenance report files'
[ "$canonical_before_run" = "$(tree_hash "$project/okf")" ] || fail 'maintenance run changed canonical memory'

first_hash="$(awk -F': ' '$1 == "brain_report_hash_sha256" { print $2; exit }' "$latest")"
[ -n "$first_hash" ] || fail 'maintenance report hash missing'
status_after="$($cli --root "$vault" maintenance status "$project_id" --principal bob --json)"
json_check "$status_after" 'value["report_state"] == "current" and value["reminder"] == "none" and value["report_hash"]'
status_hash="$(printf '%s\n' "$status_after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["report_hash"])')"
[ "$status_hash" = "$first_hash" ] || fail 'status report hash does not match latest.md'

second_run="$($cli --root "$vault" maintenance run "$project_id" --principal bob --limit 200)"
assert_contains "$second_run" 'maintenance=ok'
second_hash="$(awk -F': ' '$1 == "brain_report_hash_sha256" { print $2; exit }' "$latest")"
[ "$first_hash" = "$second_hash" ] || fail 'repeated maintenance run changed report hash'
grep -Fq 'malformed-receipt-line-2' "$latest" || fail 'malformed receipt finding missing from report'
grep -Fq 'index' "$latest" || fail 'index finding missing from report'
[ -f "$project/indexes/rebuild-state.json" ] || fail 'maintenance repaired or removed rebuild state'
grep -Fq 'synthetic maintenance failure' "$project/indexes/rebuild-state.json" || fail 'maintenance changed failed index state'

hidden_hash="$(shasum -a 256 "$project/okf/claims/hidden-maintenance.md" | awk '{print $1}')"
assert_not_contains "$(cat "$latest")" "$hidden_hash"

schedule="$($cli --root "$vault" maintenance schedule declare "$project_id" --name 'weekly memory review' --cadence weekly --runner hermes --max-age-days 7)"
assert_contains "$schedule" 'schedule_state=declared-unverified'
schedule_file="$project/maintenance/schedule.md"
[ -f "$schedule_file" ] || fail 'schedule declaration missing'
grep -Fq 'type: MaintenanceSchedule' "$schedule_file" || fail 'schedule type missing'
grep -Fq 'brain_schedule_state: declared-unverified' "$schedule_file" || fail 'schedule was presented as verified'
grep -Fq 'brain_schedule_runner: hermes' "$schedule_file" || fail 'schedule runner missing'
declared_status="$($cli --root "$vault" maintenance status "$project_id" --principal bob --json)"
json_check "$declared_status" 'value["schedule_state"] == "declared-unverified"'

disabled="$($cli --root "$vault" maintenance schedule disable "$project_id")"
assert_contains "$disabled" 'schedule_state=disabled'
grep -Fq 'brain_schedule_state: disabled' "$schedule_file" || fail 'disable did not preserve disabled marker'
grep -Fq 'weekly memory review' "$schedule_file" || fail 'disable deleted schedule history'
disabled_status="$($cli --root "$vault" maintenance status "$project_id" --principal bob --json)"
json_check "$disabled_status" 'value["schedule_state"] == "disabled" and value["reminder"] in {"none", "report-stale", "run-or-schedule"}'

# Make the last report stale and verify the reminder is actionable only when a
# schedule is declared. The status command remains read-only.
"$cli" --root "$vault" maintenance schedule declare "$project_id" --name 'weekly memory review' --cadence weekly --runner hermes --max-age-days 7 >/dev/null
python3 - "$latest" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r'(?m)^brain_report_generated_at: .*$', 'brain_report_generated_at: "2020-01-01T00:00:00Z"', text, count=1)
path.write_text(text, encoding="utf-8")
PY
# The implementation may use the filesystem mtime as the conservative
# freshness signal.  Move both representations into the past so this fixture
# exercises stale-report handling without changing the report hash contract.
touch -t 202001010000 "$latest"
stale_status="$($cli --root "$vault" maintenance status "$project_id" --principal bob --json)"
json_check "$stale_status" 'value["report_state"] == "stale" and value["reminder"] == "report-stale"'
if "$cli" --root "$vault" maintenance status "$project_id" --principal bob --strict >/dev/null 2>&1; then
  fail 'strict status accepted stale report'
fi

printf '%s\n' 'llm-brain maintenance self-check passed'
