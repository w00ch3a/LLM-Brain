#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-planner.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_retrieval_planner_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
printf 'deploy-release-v2 evidence from source\n' >"$fixture/source.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/source.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_id="$(basename "$episode_file" .md)"
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"

write_claim() {
  local file="$1" claim_id="$2" principal="$3"
  {
    printf '%s\n' '---'
    printf '%s\n' 'type: Claim' 'title: Release deployment identifier' 'status: stable'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $claim_id" 'brain_review_state: approved'
    printf '%s\n' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_source_authority: repository'
    printf '%s\n' "brain_principal: $principal" "brain_provenance: episode://$episode_id" 'brain_schema_version: 3'
    printf '%s\n' '---' '# Release deployment identifier' '' 'The deploy-release-v2 identifier is retained with its source evidence.'
  } >"$file"
}

write_claim "$project_dir/okf/claims/alpha.md" alpha agent-alpha
write_claim "$project_dir/okf/claims/beta.md" beta agent-beta

metadata="$fixture/search.metadata"
exact="$($cli --root "$vault" search "$project_id" deploy-release-v2 --strategy hybrid --intent exact_identifier --principal agent-alpha --metadata-file "$metadata" --limit 10)"
grep -Fq 'okf/claims/alpha.md' <<<"$exact"
! grep -Fq 'okf/claims/beta.md' <<<"$exact"
grep -Fq 'retrieval_mode=lexical' "$metadata"
grep -Fq 'intent=exact_identifier' "$metadata"
grep -Fq 'principal=agent-alpha' "$metadata"

evidence="$($cli --root "$vault" search "$project_id" deploy-release-v2 --intent evidence --require-evidence --metadata-file "$metadata" --limit 10)"
grep -Fq 'okf/claims/alpha.md' <<<"$evidence"
grep -Fq 'require_evidence=true' "$metadata"
grep -Fq 'episodes/' "$metadata"
grep -Fq 'sources/' "$metadata"

exploratory="$($cli --root "$vault" search "$project_id" deploy-release-v2 --intent exploratory --exploratory --limit 10)"
[ "$(printf '%s\n' "$exploratory" | tail -n +2 | cut -f9 | sort -u | wc -l | tr -d ' ')" = 1 ]

pack_result="$($cli --root "$vault" pack build "$project_id" --task deploy-release-v2 --intent evidence --require-evidence --budget-tokens 800)"
pack_file="$(printf '%s\n' "$pack_result" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$pack_file" ]
grep -Fq 'brain_planner: deterministic' "$pack_file"
grep -Fq 'brain_require_evidence: true' "$pack_file"
grep -Fq '## Supporting Evidence' "$pack_file"
grep -Fq 'Evidence ref: <code>episodes/' "$pack_file"
grep -Fq 'Evidence ref: <code>sources/' "$pack_file"

printf '%s\n' 'llm-brain retrieval planner self-check passed'
