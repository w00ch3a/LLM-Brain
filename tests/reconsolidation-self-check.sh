#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-reconcile.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_reconsolidation_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"
{
  printf '%s\n' '---' 'type: Claim' 'title: Current release rule' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: current-rule' 'brain_review_state: approved'
  printf '%s\n' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_schema_version: 3'
  printf '%s\n' '---' '# Current release rule' '' 'The current release rule is retained.'
} >"$project_dir/okf/claims/current-rule.md"
before="$(shasum -a 256 "$project_dir/okf/claims/current-rule.md" | awk '{print $1}')"
cat >"$fixture/contradiction.md" <<'SOURCE'
CONTRADICTS: okf/claims/current-rule.md
The current release rule changed after a failed verification.
SOURCE
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/contradiction.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_ref="${episode_file#"$project_dir/"}"
review_file="$(find "$project_dir/review" -maxdepth 1 -type f -name 'reconsolidation_*.md' | head -n 1)"
[ -f "$review_file" ]
grep -Fq 'brain_review_kind: reconsolidation' "$review_file"
grep -Fq 'brain_prediction_error: explicit-contradiction' "$review_file"
grep -Fq 'brain_recalled_ref: "okf/claims/current-rule.md"' "$review_file"
grep -Fq "brain_new_evidence_ref: \"$episode_ref\"" "$review_file"
review_id="$(basename "$review_file" .md)"
"$cli" --root "$vault" review decide "$project_id" "$review_id" approved --reason 'validated as a contradiction record' >/dev/null
grep -Fq 'brain_review_state: approved' "$review_file"

after="$(shasum -a 256 "$project_dir/okf/claims/current-rule.md" | awk '{print $1}')"
[ "$before" = "$after" ]

summary="$($cli --root "$vault" projection build "$project_id" "$episode_ref" --resolution summary)"
summary_id="$(printf '%s\n' "$summary" | sed -n 's/.*projection_id=\([^ ]*\).*/\1/p')"
detail="$($cli --root "$vault" projection build "$project_id" "$episode_ref" --resolution detail --span 1:2)"
detail_id="$(printf '%s\n' "$detail" | sed -n 's/.*projection_id=\([^ ]*\).*/\1/p')"
[ "$summary_id" != "$detail_id" ]
grep -Fq 'brain_projection_resolution: summary' "$project_dir/projections/$summary_id.md"
grep -Fq 'brain_projection_resolution: detail' "$project_dir/projections/$detail_id.md"
grep -Fq 'brain_projection_span: "1:2"' "$project_dir/projections/$detail_id.md"
"$cli" --root "$vault" projection retract "$project_id" "$detail_id" --reason 'projection no longer needed' >/dev/null
grep -Fq 'brain_projection_state: retracted' "$project_dir/projections/$detail_id.md"
grep -Fq 'brain_retracts: ' "$project_dir/projections/retractions/$detail_id.md"

printf '%s\n' 'llm-brain reconsolidation self-check passed'
