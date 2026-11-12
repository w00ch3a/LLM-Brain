#!/usr/bin/env bash
# #15 (11 Nov ideas): judge a pack at the point of use (new vs already
# visible, used later or not), report it in evals beside task success, and
# hold a compression that drops the answer-bearing content.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-pou.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'pack point-of-use self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_pou"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"; claims="$project_dir/okf/claims"
b() { "$cli" --root "$vault" "$@"; }
claim() {
  local id="$1" title="$2" body="$3"
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
claim port 'Staging port' 'The staging deploy listens on port 8443 behind Caddy.'
claim region 'Staging region' 'Staging deploys run in region ap-southeast-2 on Fridays.'
claim owner 'Staging owner' 'The staging deploy rota is owned by Priya until December.'
checks=()

pack="$(b pack build "$project_id" --task 'staging deploy' --budget-tokens 4000 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
pack_ref="${pack#"$project_dir/"}"
printf 'Earlier in this session: staging listens on port 8443 behind Caddy.\n' >"$fixture/visible.txt"
printf 'Deployed to ap-southeast-2 on port 8443.\n' >"$fixture/later.txt"

# 1. Per-record judgement and pack verdict.
judged="$(b pack judge "$project_id" --pack "$pack_ref" --visible "$fixture/visible.txt" --later "$fixture/later.txt")"
grep -Fxq $'okf/claims/port.md\talready-visible\tused' <<<"$judged" || fail "port should be already-visible: $judged"
grep -Fxq $'okf/claims/region.md\tnovel\tused' <<<"$judged" || fail "region should be novel+used: $judged"
grep -Fxq $'okf/claims/owner.md\tnovel\tunused' <<<"$judged" || fail "owner should be novel+unused: $judged"
grep -Fq $'novel_used=1\tverdict=used' <<<"$judged" || fail "pack verdict wrong: $judged"
checks+=(novel_vs_visible_and_used=ok)

# 2. A pack that only repeats what the agent already saw is redundant.
cat "$claims"/*.md >"$fixture/all-visible.txt"
grep -Fq 'verdict=redundant' <<<"$(b pack judge "$project_id" --pack "$pack_ref" --visible "$fixture/all-visible.txt" --later "$fixture/later.txt")" || fail 'redundant pack not flagged'
checks+=(redundant_pack_flagged=ok)

# 3. --record credits only records that were new and used (#14).
out="$(b pack judge "$project_id" --pack "$pack_ref" --visible "$fixture/visible.txt" --later "$fixture/later.txt" --record)"
grep -Fq 'used=["okf/claims/region.md"]' <<<"$out" || fail "record did not credit only region: $out"
checks+=(record_credits_new_and_used=ok)

# 4. Eval: success alone vs success that used memory.
printf 'case_id\tquery\texpected_paths\ttask\nregion\tstaging deploy region\tokf/claims/region.md\twhich region\nowner\tstaging deploy rota owner\tokf/claims/owner.md\twho owns the rota\n' >"$fixture/cases.tsv"
cat >"$fixture/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
# Answers the region case from memory; answers the owner case generically.
if grep -q 'case_id: region' "$1"; then printf 'outcome: success\nIt runs in ap-southeast-2 on Fridays.\n' >"$2"
else printf 'outcome: success\nAsk the team lead.\n' >"$2"; fi
RUNNER
chmod 755 "$fixture/runner.sh"
out="$(b eval run "$project_id" --cases "$fixture/cases.tsv" --strategies lexical --answer-runner "$fixture/runner.sh" --output "$fixture/eval")"
grep -Fq '## Point of use' "$fixture/eval/report.md" || fail "no point-of-use section: $(cat "$fixture/eval/report.md")"
row="$(awk -F '\t' '$1 == "lexical" && NF == 6' "$fixture/eval/report.md" | tail -n 1)"
[ "$(cut -f2-4 <<<"$row")" = $'2\t2\t1' ] || fail "expected 2 answers, 2 successes, 1 without memory use: $row"
awk -F '\t' 'NR > 1 && $1 == "region" && $17 >= 1 { f=1 } END { exit !f }' "$fixture/eval/trace.tsv" || fail 'region case not credited with use'
awk -F '\t' 'NR > 1 && $1 == "owner" && $17 == 0 { f=1 } END { exit !f }' "$fixture/eval/trace.tsv" || fail 'owner case wrongly credited'
checks+=(eval_success_without_memory_use=ok)

# 5. Compression keeps the answer: a task-blind summary is held; one that keeps
# the answer-bearing tokens and the task's own terms lands.
mkreview() {
  printf -- '---\ntype: ReviewItem\ntitle: "%s"\nbrain_project_id: %s\nbrain_candidate_id: %s\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: internal\nbrain_loading_temperature: warm\nbrain_source_authority: user\nbrain_provider_id: fixture\nbrain_provider_version: "1"\nbrain_provenance: "episode://fixture"\n%sbrain_schema_version: 3\n---\n# %s\n\n%s\n' \
    "$2" "$project_id" "$1" "$4" "$2" "$3" >"$project_dir/review/$1.md"
}
mkreview claim_cmp_blind 'Staging owner (short)' 'Someone owns the staging deploy rota.' $'brain_compressed_from: ["okf/claims/owner.md"]\n'
set +e; out="$(b review decide "$project_id" claim_cmp_blind approved --actor human:test --reason compress 2>&1)"; rc=$?; set -e
[ "$rc" = 75 ] && grep -Fq 'Priya' <<<"$out" || fail "task-blind compression not held (rc=$rc): $out"
mkreview claim_cmp_task 'Staging owner (short)' 'Priya owns staging until December.' $'brain_compressed_from: ["okf/claims/owner.md"]\nbrain_preserve_terms: ["rota"]\n'
set +e; out="$(b review decide "$project_id" claim_cmp_task approved --actor human:test --reason compress 2>&1)"; rc=$?; set -e
[ "$rc" = 75 ] && grep -Fq 'rota' <<<"$out" || fail "compression lost a task term but was not held (rc=$rc): $out"
mkreview claim_cmp_good 'Staging rota owner' 'Priya owns the staging rota until December.' $'brain_compressed_from: ["okf/claims/owner.md"]\nbrain_preserve_terms: ["rota"]\n'
b review decide "$project_id" claim_cmp_good approved --actor human:test --reason compress >/dev/null || fail 'answer-preserving compression refused'
[ -f "$claims/claim_cmp_good.md" ] || fail 'compression not promoted'
checks+=(compression_keeps_answer=ok)

printf 'pack point-of-use self-check passed: %s\n' "${checks[*]}"
