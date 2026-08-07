#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-eval.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_eval_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
printf 'source retrieval identifier\n' >"$fixture/source.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/source.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
project_dir="$vault/projects/$project_id"
source_rel="$(find "$project_dir/sources" -maxdepth 1 -type f -name '*.md' | head -n 1 | sed "s#^$project_dir/##")"
episode_rel="${episode_file#"$project_dir/"}"
mkdir -p "$project_dir/okf/claims"
{
  printf '%s\n' '---'
  printf '%s\n' 'type: Claim' 'title: Source retrieval identifier' 'status: stable'
  printf '%s\n' 'generated: {by: process:test, at: 2026-08-07T00:00:00Z}' 'sources: [{resource: source://fixture}]'
  printf '%s\n' "brain_project_id: $project_id" 'brain_claim_id: source-claim' 'brain_review_state: approved'
  printf '%s\n' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal'
  printf '%s\n' 'brain_source_authority: repository' 'brain_provenance: human://fixture' 'brain_schema_version: 3'
  printf '%s\n' '---' '# Source retrieval identifier' '' 'source retrieval identifier.'
} >"$project_dir/okf/claims/source-claim.md"

cat >"$fixture/embedder.sh" <<'EMBEDDER'
#!/usr/bin/env bash
printf 'model: eval-fixture\ndimensions: 2\nvector: 1 0\n'
EMBEDDER
chmod 755 "$fixture/embedder.sh"
"$cli" --root "$vault" index build "$project_id" --embedder "$fixture/embedder.sh" >/dev/null
"$cli" --root "$vault" lint --project "$project_id" --strict >/dev/null

printf 'case_id\tquery\texpected_paths\ttask\nsource\tsource retrieval\tokf/claims/source-claim.md,%s,%s\tfind source retrieval\n' "$source_rel" "$episode_rel" >"$fixture/cases.tsv"

before="$(shasum -a 256 "$project_dir/okf/claims/source-claim.md" | awk '{print $1}')"
first="$($cli --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies none,source,episode,lexical,vector,hybrid,graph --query-embedder "$fixture/embedder.sh")"
output="$(printf '%s\n' "$first" | sed -n 's/.*output=\([^ ]*\).*/\1/p')"
[ -f "$output/report.md" ]
[ -f "$output/trace.tsv" ]
grep -Fq $'vector\tvector\tfalse' "$output/trace.tsv"
grep -Fq $'hybrid\thybrid-rrf\tfalse' "$output/trace.tsv"
grep -Fq $'lexical\tlexical\tfalse' "$output/trace.tsv"
grep -Fq $'source\tsource\tfalse' "$output/trace.tsv"
grep -Fq 'brain_result_hash_sha256:' "$output/report.md"
after="$(shasum -a 256 "$project_dir/okf/claims/source-claim.md" | awk '{print $1}')"
[ "$before" = "$after" ]

second="$($cli --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies none,source,episode,lexical,vector,hybrid,graph --query-embedder "$fixture/embedder.sh")"
grep -Fq 'eval=idempotent' <<<"$second"

printf '\nHistory changed.\n' >>"$project_dir/okf/claims/source-claim.md"
"$cli" --root "$vault" index build "$project_id" --embedder "$fixture/embedder.sh" >/dev/null
changed="$($cli --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies none,source,episode,lexical,vector,hybrid,graph --query-embedder "$fixture/embedder.sh")"
changed_output="$(printf '%s\n' "$changed" | sed -n 's/.*output=\([^ ]*\).*/\1/p')"
[ "$changed_output" != "$output" ]

for number in $(seq -w 0 20); do
  sed -e "s/source-claim/cutoff-$number/g" -e 's/Source retrieval identifier/Top cutoff fixture/g' -e 's/source retrieval identifier\./top cutoff fixture./g' "$project_dir/okf/claims/source-claim.md" >"$project_dir/okf/claims/cutoff-$number.md"
done
printf 'case_id\tquery\texpected_paths\ttask\ncutoff\ttop cutoff fixture\tokf/claims/cutoff-20.md\ttop twenty only\n' >"$fixture/cutoff-cases.tsv"
cutoff="$($cli --root "$vault" eval run "$project_id" --cases "$fixture/cutoff-cases.tsv" --strategies lexical)"
cutoff_output="$(printf '%s\n' "$cutoff" | sed -n 's/.*output=\([^ ]*\).*/\1/p')"
awk -F '\t' 'NR == 2 && $9 == "false" && split($6, paths, ",") == 20 { found = 1 } END { exit !found }' "$cutoff_output/trace.tsv"

cat >"$fixture/answer-runner.sh" <<'RUNNER'
#!/usr/bin/env bash
printf 'outcome: pass\n' >"$2"
RUNNER
chmod 755 "$fixture/answer-runner.sh"
answer="$($cli --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies lexical --answer-runner "$fixture/answer-runner.sh")"
answer_output="$(printf '%s\n' "$answer" | sed -n 's/.*output=\([^ ]*\).*/\1/p')"
awk -F '\t' 'NR > 1 && $12 == 1 && $13 == 0 && $15 == "pass" { found = 1 } END { exit !found }' "$answer_output/trace.tsv"

printf '%s\n' 'llm-brain evaluation self-check passed'
