#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-experiments.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_experimental_gates_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims"
{
  printf '%s\n' '---' 'type: Claim' 'title: Experimental recalled rule' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: recalled-rule' 'brain_review_state: approved'
  printf '%s\n' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_schema_version: 3'
  printf '%s\n' '---' '# Experimental recalled rule' '' 'The recalled rule is unchanged.'
} >"$project_dir/okf/claims/recalled-rule.md"
printf 'prediction evidence\n' >"$fixture/evidence.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/evidence.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_ref="${episode_file#"$project_dir/"}"

status="$($cli --root "$vault" experiment status "$project_id")"
grep -Fq $'prediction-error\tLLM_BRAIN_EXPERIMENT_PREDICTION_ERROR\tdisabled' <<<"$status"
grep -Fq $'causal-selection\tLLM_BRAIN_EXPERIMENT_CAUSAL_SELECTION\tdisabled\tnegative-no-evidence' <<<"$status"

disabled="$($cli --root "$vault" experiment prediction "$project_id" "$episode_ref" --expected old --observed new --recalled okf/claims/recalled-rule.md)"
grep -Fq 'state=disabled error=1' <<<"$disabled"
[ "$(find "$project_dir/review" -maxdepth 1 -type f -name 'reconsolidation_*.md' | wc -l | tr -d ' ')" = 0 ]

enabled="$(LLM_BRAIN_EXPERIMENT_PREDICTION_ERROR=1 "$cli" --root "$vault" experiment prediction "$project_id" "$episode_ref" --expected old --observed new --recalled okf/claims/recalled-rule.md)"
grep -Fq 'state=recorded error=1' <<<"$enabled"
[ "$(find "$project_dir/review" -maxdepth 1 -type f -name 'reconsolidation_*.md' | wc -l | tr -d ' ')" = 1 ]

run="$($cli --root "$vault" run start "$project_id" okf/claims/recalled-rule.md --request-id replay-request)"
run_id="$(printf '%s\n' "$run" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
"$cli" --root "$vault" run outcome "$project_id" "$run_id" --status failed --summary 'fixture failure' >/dev/null
replay="$($cli --root "$vault" experiment replay "$project_id" "$run_id" --mode failure)"
grep -Fq 'state=disabled' <<<"$replay"
replay_enabled="$(LLM_BRAIN_EXPERIMENT_PROCEDURE_REPLAY=1 "$cli" --root "$vault" experiment replay "$project_id" "$run_id" --mode failure)"
grep -Fq 'state=recorded' <<<"$replay_enabled"

gate="$($cli --root "$vault" experiment record "$project_id" causal-selection --status negative --reason 'No causal evidence gate passed' --evidence "$episode_ref")"
gate_file="$(printf '%s\n' "$gate" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_experiment_status: negative' "$gate_file"
grep -Fq 'brain_evidence_hash_sha256:' "$gate_file"

printf '%s\n' 'llm-brain experimental gates self-check passed'
