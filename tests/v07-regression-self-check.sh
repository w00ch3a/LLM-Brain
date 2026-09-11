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
bridge_output="$($cli --root "$vault" bridge recall --source-root "$repo_root" --project-id "$project_id" --query-file "$fixture/query.txt" --receipt)"
grep -Fq 'receipt-claim.md' <<<"$bridge_output"
! grep -Fq 'Receipt privacy fixture' "$audit"

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
