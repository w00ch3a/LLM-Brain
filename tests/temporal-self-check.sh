#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-temporal.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_temporal_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"

{
  printf '%s\n' '---' 'type: Claim' 'title: Temporal policy current' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: current' 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository'
  printf '%s\n' 'brain_valid_from: "2026-08-01T00:00:00Z"' 'brain_valid_to: "2026-09-01T00:00:00Z"' '---' '# Temporal policy current' '' 'Temporal policy current.'
} >"$project_dir/okf/claims/current.md"
{
  printf '%s\n' '---' 'type: Claim' 'title: Temporal policy future' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: future' 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository'
  printf '%s\n' 'brain_valid_from: "2026-09-01T00:00:00Z"' '---' '# Temporal policy future' '' 'Temporal policy future.'
} >"$project_dir/okf/claims/future.md"

current="$($cli --root "$vault" search "$project_id" 'Temporal policy' --as-of 2026-08-07T00:00:00Z --limit 10)"
grep -Fq 'okf/claims/current.md' <<<"$current"
! grep -Fq 'okf/claims/future.md' <<<"$current"

future="$($cli --root "$vault" search "$project_id" 'Temporal policy' --as-of 2026-09-15T00:00:00Z --limit 10)"
grep -Fq 'okf/claims/future.md' <<<"$future"
! grep -Fq 'okf/claims/current.md' <<<"$future"

historical="$($cli --root "$vault" search "$project_id" 'Temporal policy' --historical --limit 10)"
grep -Fq 'okf/claims/current.md' <<<"$historical"
grep -Fq 'okf/claims/future.md' <<<"$historical"

{
  printf '%s\n' '---' 'type: Claim' 'title: Invalid temporal interval' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: invalid' 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository'
  printf '%s\n' 'brain_valid_from: "2026-09-01T00:00:00Z"' 'brain_valid_to: "2026-08-01T00:00:00Z"' '---' '# Invalid temporal interval'
} >"$project_dir/okf/claims/invalid.md"
if "$cli" --root "$vault" lint --project "$project_id" --strict >/dev/null 2>&1; then
  exit 1
fi
rm "$project_dir/okf/claims/invalid.md"

printf 'observed source\n' >"$fixture/observed.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/observed.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
candidate="$fixture/laundered.md"
{
  printf '%s\n' '---' 'type: ReviewItem' 'title: Laundered authority' 'brain_review_kind: claim' 'brain_confidence: 0.99' 'brain_risk: low' 'brain_sensitivity: internal'
  printf '%s\n' 'brain_source_authority: repository' 'brain_authority_origin: external-observation' 'brain_provider_id: fixture-provider' 'brain_provider_version: 1'
  printf '%s\n' "brain_provenance: \"episode://$(basename "$episode_file" .md)\"" '---' '# Laundered authority' '' 'An external observation must not become repository authority.'
} >"$candidate"
queued="$($cli --root "$vault" reflect submit "$project_id" "$candidate")"
grep -Fq 'review=queued' <<<"$queued"
review_id="$(printf '%s\n' "$queued" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
[ -n "$review_id" ]
[ ! -f "$project_dir/okf/claims/$review_id.md" ]

printf '%s\n' 'llm-brain temporal self-check passed'
