#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-run.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_procedure_run_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/procedures"
{
  printf '%s\n' '---' 'type: Procedure' 'title: Safe release procedure' 'status: stable'
  printf '%s\n' "brain_project_id: $project_id" 'brain_procedure_id: safe-release' 'brain_review_state: approved'
  printf '%s\n' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_schema_version: 3'
  printf '%s\n' '---' '# Safe release procedure' '' 'Run the checks and record the outcome.'
} >"$project_dir/okf/procedures/safe-release.md"
printf 'procedure evidence\n' >"$fixture/evidence.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/evidence.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_ref="${episode_file#"$project_dir/"}"

before="$(shasum -a 256 "$project_dir/okf/procedures/safe-release.md" | awk '{print $1}')"
started="$($cli --root "$vault" run start "$project_id" okf/procedures/safe-release.md --task 'release checks' --request-id request-release-1 --branch main --obligation verify-artifacts)"
run_id="$(printf '%s\n' "$started" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
[ -n "$run_id" ]
started_again="$($cli --root "$vault" run start "$project_id" okf/procedures/safe-release.md --task 'release checks' --request-id request-release-1 --branch main --obligation verify-artifacts)"
grep -Fq "run_id=$run_id" <<<"$started_again"

outcome="$($cli --root "$vault" run outcome "$project_id" "$run_id" --status success --summary 'All checks passed' --evidence "$episode_ref" --verified-by process:test)"
outcome_id="$(printf '%s\n' "$outcome" | sed -n 's/.*outcome_id=\([^ ]*\).*/\1/p')"
[ -n "$outcome_id" ]
grep -Fq 'verification=verified' <<<"$outcome"
run_status="$($cli --root "$vault" run status "$project_id")"
printf '%s\n' "$run_status" | awk -F '\t' -v id="$run_id" '$1 == id && $2 == "success" && $4 == "verified" { found=1 } END { exit !found }'
outcome_file="$project_dir/runs/outcomes/$outcome_id.md"
grep -Fq 'brain_outcome_status: success' "$outcome_file"
grep -Fq -- '- ref:' <(sed -n '/## Evidence/,$p' "$outcome_file")

after="$(shasum -a 256 "$project_dir/okf/procedures/safe-release.md" | awk '{print $1}')"
[ "$before" = "$after" ]
[ "$(find "$project_dir/runs/outcomes" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = 1 ]

printf '%s\n' 'llm-brain procedure run self-check passed'
