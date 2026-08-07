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

cat >"$fixture/shadow-evidence.md" <<'SHADOW'
PREDICTION_EXPECTED: old
PREDICTION_OBSERVED: changed
PREDICTION_RECALLED: okf/claims/recalled-rule.md
SHADOW
LLM_BRAIN_EXPERIMENT_PREDICTION_ERROR=shadow "$cli" --root "$vault" ingest-source "$project_id" "$fixture/shadow-evidence.md" >/dev/null
grep -Fq 'brain_experiment_state: shadow' "$project_dir"/experiments/predictions/*.md
[ "$(find "$project_dir/review" -maxdepth 1 -type f -name 'reconsolidation_*.md' | wc -l | tr -d ' ')" = 0 ]
prediction_count="$(find "$project_dir/experiments/predictions" -type f -name '*.md' | wc -l | tr -d ' ')"
LLM_BRAIN_EXPERIMENT_PREDICTION_ERROR=shadow "$cli" --root "$vault" ingest-source "$project_id" "$fixture/shadow-evidence.md" >/dev/null
[ "$(find "$project_dir/experiments/predictions" -type f -name '*.md' | wc -l | tr -d ' ')" = "$prediction_count" ]

enabled="$(LLM_BRAIN_EXPERIMENT_PREDICTION_ERROR=1 "$cli" --root "$vault" experiment prediction "$project_id" "$episode_ref" --expected old --observed new --recalled okf/claims/recalled-rule.md)"
grep -Fq 'state=recorded error=1' <<<"$enabled"
[ "$(find "$project_dir/review" -maxdepth 1 -type f -name 'reconsolidation_*.md' | wc -l | tr -d ' ')" = 1 ]

run="$($cli --root "$vault" run start "$project_id" okf/claims/recalled-rule.md --request-id replay-request)"
run_id="$(printf '%s\n' "$run" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
"$cli" --root "$vault" run outcome "$project_id" "$run_id" --status failed --summary 'fixture failure' >/dev/null
replay="$($cli --root "$vault" experiment replay "$project_id" "$run_id" --mode failure)"
grep -Fq 'state=disabled' <<<"$replay"

successful_run="$($cli --root "$vault" run start "$project_id" okf/claims/recalled-rule.md --request-id replay-success-request)"
successful_run_id="$(printf '%s\n' "$successful_run" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
"$cli" --root "$vault" run outcome "$project_id" "$successful_run_id" --status success --summary 'fixture success' >/dev/null
replay_enabled="$(LLM_BRAIN_EXPERIMENT_PROCEDURE_REPLAY=1 "$cli" --root "$vault" experiment replay "$project_id" "$run_id" --mode failure)"
grep -Fq 'state=recorded recommendation=compare-successful-run-differences comparisons=1' <<<"$replay_enabled"
replay_file="$(printf '%s\n' "$replay_enabled" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_success_count: 1' "$replay_file"
grep -Fq 'brain_failed_count: 1' "$replay_file"
[ "$(find "$project_dir/review" -maxdepth 1 -type f -name 'procedure_replay_*.md' | wc -l | tr -d ' ')" = 1 ]
replay_review_id="$(printf '%s\n' "$replay_enabled" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
canonical_before="$(shasum -a 256 "$project_dir/okf/claims/recalled-rule.md" | awk '{print $1}')"
"$cli" --root "$vault" review decide "$project_id" "$replay_review_id" approved --actor human:test --reason 'fixture review' >/dev/null
[ "$(shasum -a 256 "$project_dir/okf/claims/recalled-rule.md" | awk '{print $1}')" = "$canonical_before" ]

gate="$($cli --root "$vault" experiment record "$project_id" causal-selection --status negative --reason 'No causal evidence gate passed' --evidence "$episode_ref")"
gate_file="$(printf '%s\n' "$gate" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_experiment_status: negative' "$gate_file"
grep -Fq 'brain_evidence_hash_sha256:' "$gate_file"

printf '%s\n' 'llm-brain experimental gates self-check passed'
