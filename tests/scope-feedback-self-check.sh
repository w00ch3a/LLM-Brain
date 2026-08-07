#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-feedback.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_scope_feedback_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"
{
  printf '%s\n' '---' 'type: Claim' 'title: Scoped release rule' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: scoped-rule' 'brain_review_state: approved'
  printf '%s\n' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_principal: agent-alpha' 'brain_audience: release-team' 'brain_schema_version: 3'
  printf '%s\n' '---' '# Scoped release rule' '' 'Scoped release context for the agent.'
} >"$project_dir/okf/claims/scoped-rule.md"
printf 'scope evidence\n' >"$fixture/evidence.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/evidence.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_ref="${episode_file#"$project_dir/"}"

pack_result="$($cli --root "$vault" pack build "$project_id" --task 'scoped release rule' --principal agent-alpha --budget-tokens 400)"
pack_file="$(printf '%s\n' "$pack_result" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$pack_file" ]
grep -Fq 'brain_principal: "agent-alpha"' "$pack_file"
pack_ref="${pack_file#"$project_dir/"}"

feedback="$($cli --root "$vault" feedback record "$project_id" --pack "$pack_ref" --usefulness useful --principal agent-alpha --notes 'Resolved the scoped task')"
feedback_id="$(printf '%s\n' "$feedback" | sed -n 's/.*feedback_id=\([^ ]*\).*/\1/p')"
[ -f "$project_dir/feedback/$feedback_id.md" ]
feedback_again="$($cli --root "$vault" feedback record "$project_id" --pack "$pack_ref" --usefulness useful --principal agent-alpha --notes 'Resolved the scoped task')"
grep -Fq "feedback_id=$feedback_id" <<<"$feedback_again"
[ "$(find "$project_dir/feedback" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = 1 ]

association="$($cli --root "$vault" association build "$project_id" okf/claims/scoped-rule.md "$episode_ref" --reason 'shared release context')"
association_id="$(printf '%s\n' "$association" | sed -n 's/.*association_id=\([^ ]*\).*/\1/p')"
association_file="$project_dir/projections/$association_id.md"
grep -Fq 'brain_association_relation: associates' "$association_file"
grep -Fq 'brain_association_a: "okf/claims/scoped-rule.md"' "$association_file"
grep -Fq "brain_association_b: \"$episode_ref\"" "$association_file"
"$cli" --root "$vault" association retract "$project_id" "$association_id" --reason 'association was exploratory' >/dev/null
grep -Fq 'brain_projection_state: retracted' "$association_file"
grep -Fq "$association_id" "$project_dir/projections/retractions/$association_id.md"

printf '%s\n' 'llm-brain scope and feedback self-check passed'
