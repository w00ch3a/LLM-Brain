#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-v07.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id=proj_v07_regression
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"
cat >"$project_dir/okf/claims/receipt-claim.md" <<EOF
---
type: Claim
title: Receipt privacy fixture
status: stable
brain_project_id: $project_id
brain_claim_id: receipt-claim
brain_review_state: approved
brain_source_authority: repository
brain_sensitivity: internal
brain_schema_version: 3
---
# Receipt privacy fixture

Synthetic evidence for v0.7 regression coverage.
EOF
printf 'Synthetic evidence custody.\n' >"$fixture/evidence.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/evidence.md")"
episode_file="$(sed -n 's/.*episode=\([^ ]*\).*/\1/p' <<<"$captured" | tail -1)"
episode_id="$(basename "$episode_file" .md)"
awk -v provenance="brain_provenance: episode://$episode_id" '{ print; if ($0 ~ /^brain_schema_version:/) print provenance }' \
  "$project_dir/okf/claims/receipt-claim.md" >"$fixture/claim.tmp"
mv "$fixture/claim.tmp" "$project_dir/okf/claims/receipt-claim.md"

audit="$project_dir/audit/retrieval-receipts.jsonl"
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' >/dev/null
[ ! -e "$audit" ] || { echo 'receipt unexpectedly written by default' >&2; exit 1; }

"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt >/dev/null
[ -f "$audit" ]
receipt_count="$(wc -l <"$audit" | tr -d ' ')"
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt >/dev/null
[ "$(wc -l <"$audit" | tr -d ' ')" = "$receipt_count" ] || { echo 'receipt was not idempotent' >&2; exit 1; }
! grep -Fq 'Receipt privacy fixture' "$audit"

evidence_output="$($cli --root "$vault" search "$project_id" 'Receipt privacy fixture' --intent evidence --require-evidence --receipt)"
grep -Fq 'receipt-claim.md' <<<"$evidence_output"

pack_output="$($cli --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture' --receipt)"
grep -Fq 'file=' <<<"$pack_output"
[ "$(wc -l <"$audit" | tr -d ' ')" -ge 2 ]
printf 'Receipt privacy fixture\n' >"$fixture/query.txt"
bridge_output="$($cli --root "$vault" bridge recall --source-root "$repo_root" --project-id "$project_id" --query-file "$fixture/query.txt" --require-evidence --receipt)"
grep -Fq 'receipt-claim.md' <<<"$bridge_output"
! grep -Fq 'Receipt privacy fixture' "$audit"
printf '%s\n' "$bridge_output" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["evidence_opened"] is True and p["evidence_incomplete"] is False'
source_file="$(find "$project_dir/sources" -maxdepth 1 -type f -name '*.md' -print -quit)"
stable_pack_output="$($cli --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture' --intent evidence)"
stable_pack="$(printf '%s\n' "$stable_pack_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Evidence ref:' "$stable_pack"
stable_required_output="$($cli --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture' --require-evidence)"
stable_required="$(printf '%s\n' "$stable_required_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
cp "$source_file" "$fixture/source-original.md"
printf 'changed source bytes\n' >>"$source_file"
changed="$($cli --root "$vault" bridge recall --source-root "$repo_root" --project-id "$project_id" --query-file "$fixture/query.txt" --intent evidence)"
printf '%s\n' "$changed" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["evidence_opened"] is False and p["evidence_incomplete"] is True; assert "### Supporting evidence" not in p["context_markdown"]'
changed_pack_output="$($cli --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture' --intent evidence)"
changed_pack="$(printf '%s\n' "$changed_pack_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ "$changed_pack" != "$stable_pack" ] || { echo 'evidence pack reused stale custody' >&2; exit 1; }
grep -Fq 'Evidence incomplete:' "$changed_pack"
changed_required_output="$($cli --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture' --require-evidence)"
changed_required="$(printf '%s\n' "$changed_required_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ "$changed_required" != "$stable_required" ] || { echo 'required-evidence pack reused stale custody' >&2; exit 1; }
cp "$fixture/source-original.md" "$source_file"
cp "$project_dir/okf/claims/receipt-claim.md" "$fixture/claim-original.md"
awk '{ print; if ($0 ~ /^brain_schema_version:/) print "brain_principal: other-agent" }' \
  "$fixture/claim-original.md" >"$project_dir/okf/claims/receipt-claim.md"
hidden="$($cli --root "$vault" bridge recall --source-root "$repo_root" --project-id "$project_id" --query-file "$fixture/query.txt" --principal alice --intent evidence)"
printf '%s\n' "$hidden" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["evidence_opened"] is False and "receipt-claim.md" not in p["context_markdown"] and "Receipt privacy fixture" not in p["context_markdown"]'
cp "$fixture/claim-original.md" "$project_dir/okf/claims/receipt-claim.md"

tiny_pack_output="$("$cli" --root "$vault" pack build "$project_id" --task 'Receipt privacy fixture tiny evidence budget' --intent evidence --budget-tokens 1 --receipt)"
tiny_pack="$(printf '%s\n' "$tiny_pack_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Context truncated:' "$tiny_pack"
grep -Fq 'Evidence incomplete:' "$tiny_pack"
python3 - "$audit" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
pack = next(row for row in reversed(rows) if row['surface'] == 'pack')
assert pack['evidence_opened'] == 'false' and pack['evidence_incomplete'] == 'true' and pack['context_truncated'] == 'true', pack
PY

"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt --principal alice >/dev/null
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt --principal bob >/dev/null
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt --intent historical >/dev/null
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt --as-of 2026-09-01T00:00:00Z >/dev/null
"$cli" --root "$vault" search "$project_id" 'Receipt privacy fixture' --receipt --as-of 2026-09-02T00:00:00Z >/dev/null
"$cli" --root "$vault" bridge recall --source-root "$repo_root" --project-id "$project_id" --query-file "$fixture/query.txt" --budget-tokens 1 --receipt >/dev/null
python3 - "$audit" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
scoped = [row for row in rows if row['surface'] == 'search' and row.get('principal') in {'alice', 'bob'}]
assert len(scoped) == 2 and scoped[0]['selected'] == scoped[1]['selected'], scoped
assert scoped[0]['receipt_id'] != scoped[1]['receipt_id']
asof = [row for row in rows if row['surface'] == 'search' and row.get('as_of', '').startswith('2026-09-0')]
assert len(asof) == 2 and asof[0]['selected'] == asof[1]['selected'] and asof[0]['receipt_id'] != asof[1]['receipt_id']
bridge = [row for row in rows if row['surface'] == 'bridge-recall']
assert len(bridge) >= 2 and len({tuple(row['rendered_selection']) for row in bridge}) >= 2
assert all(row['schema'] == 'llm-brain.retrieval-receipt.v1' and row['receipt_identity_version'] == 2 for row in rows)
assert all('rendered_selection' in row and 'as_of' in row for row in rows)
PY

preview="$($cli --root "$vault" retract "$project_id" receipt-claim --reason 'fixture cleanup' --preview --principal agent-alpha)"
cat >"$project_dir/okf/claims/hidden-dependent.md" <<EOF
---
type: Claim
title: Hidden dependant
brain_project_id: $project_id
brain_claim_id: hidden-dependent
brain_principal: other-agent
brain_review_state: approved
brain_schema_version: 3
---
# Hidden dependant
References receipt-claim.
EOF
preview_hidden="$($cli --root "$vault" retract "$project_id" receipt-claim --reason 'fixture cleanup' --preview --principal agent-alpha)"
! grep -Fq 'hidden-dependent.md' <<<"$preview_hidden"
grep -Fq 'inaccessible_scope=unknown' <<<"$preview_hidden"
token="$(sed -n 's/.* token=\([^ ]*\).*/\1/p' <<<"$preview_hidden")"
[ -n "$token" ]
mkdir -p "$project_dir/indexes"
printf 'receipt-claim.md\n' >"$project_dir/indexes/derived.txt"
mkdir -p "$project_dir/projections"
cat >"$project_dir/projections/hidden-derived.md" <<EOF
---
brain_principal: other-agent
---
Hidden derived reference to receipt-claim.
EOF
preview_hidden="$($cli --root "$vault" retract "$project_id" receipt-claim --reason 'fixture cleanup' --preview --principal agent-alpha)"
! grep -Fq 'hidden-derived.md' <<<"$preview_hidden"
token="$(sed -n 's/.* token=\([^ ]*\).*/\1/p' <<<"$preview_hidden")"
[ -n "$token" ]
if "$cli" --root "$vault" retract "$project_id" receipt-claim --reason 'fixture cleanup' --confirm stale-token >/dev/null 2>&1; then
  echo 'stale retraction token unexpectedly accepted' >&2; exit 1
fi
apply="$($cli --root "$vault" retract "$project_id" receipt-claim --reason 'fixture cleanup' --principal agent-alpha --confirm "$token")"
grep -Fq 'retraction_apply=ok' <<<"$apply"
grep -Fq 'derived.txt' <<<"$apply"
! grep -Fq 'hidden-derived.md' <<<"$apply"
grep -Fq 'receipt-claim' "$project_dir/projections/hidden-derived.md"
grep -Fq 'residual=' <<<"$apply"
grep -Fq 'residual_reason=' <<<"$apply"
if "$cli" --root "$vault" retract "$project_id" receipt-claim --reason 'fixture replay' --confirm "$token" >/dev/null 2>&1; then
  echo 'retraction token replay unexpectedly accepted' >&2; exit 1
fi
[ -f "$project_dir/okf/retractions/receipt-claim.md" ]

echo 'llm-brain v0.7 regression self-check passed'
