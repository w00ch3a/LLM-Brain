#!/usr/bin/env bash
# #14 (11 Nov ideas): credit after use, exploration for rarely retrieved
# records, and a preservation screen before a consolidation merge lands.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-credit.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'memory credit/merge self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_credit"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"; claims="$project_dir/okf/claims"
b() { "$cli" --root "$vault" "$@"; }
claim() {
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
pack_of() { sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
usage_of() { b usage "$project_id" --json | python3 -c "import json,sys; r={x['ref']:x for x in json.load(sys.stdin)['records']}; e=r['$1']; print(e['useful'], e['supported'], e['uses'])"; }
checks=()

# ---- 1. Credit after use: only the records the answer used get the credit.
claim port 'Staging port' 'The staging deploy listens on port 8443 behind Caddy.'
claim region 'Staging region' 'Staging deploys run in region ap-southeast-2 on Fridays.'
claim owner 'Staging owner' 'The staging deploy rota is owned by Priya until December.'
pack="$(b pack build "$project_id" --task 'staging deploy' --budget-tokens 4000 --receipt | pack_of)"
for ref in okf/claims/port.md okf/claims/region.md okf/claims/owner.md; do grep -Fq "Expansion: <code>$ref</code>" "$pack" || fail "fixture pack lacks $ref"; done
printf 'Point the client at port 8443; Caddy terminates TLS.\n' >"$fixture/answer.txt"
out="$(b feedback record "$project_id" --pack "${pack#"$project_dir/"}" --usefulness useful --answer "$fixture/answer.txt")"
grep -Fq 'used=["okf/claims/port.md"]' <<<"$out" || fail "attribution wrong: $out"
[ "$(usage_of okf/claims/port.md)" = "1 1 1" ] || fail "used record not credited: $(usage_of okf/claims/port.md)"
[ "$(usage_of okf/claims/owner.md)" = "0 0 1" ] || fail "unused record credited: $(usage_of okf/claims/owner.md)"
! b feedback record "$project_id" --pack "${pack#"$project_dir/"}" --usefulness useful --used okf/claims/nope.md >/dev/null 2>&1 || fail 'credit accepted for a record not in the pack'
checks+=(credit_only_used_records=ok)

# Legacy feedback (no --used/--answer) still credits the whole pack.
pack2="$(b pack build "$project_id" --task 'staging deploy rota' --budget-tokens 4000 | pack_of)"
b feedback record "$project_id" --pack "${pack2#"$project_dir/"}" --usefulness useful >/dev/null
[ "$(usage_of okf/claims/owner.md | cut -d' ' -f1)" = 1 ] || fail 'legacy whole-pack credit changed'
checks+=(legacy_feedback_unchanged=ok)

# ---- 2. Exploration: a record retrieved once but never credited keeps a slot.
for n in 1 2 3 4 5; do claim "ops-$n" "Ops rule $n" "Ops rule $n covers the release checklist."; done
claim ops-6 'Ops note 6' 'Ops note 6 mentions the checklist.'
claim ops-7 'Ops note 7' 'Ops note 7 mentions the checklist.'
used=(); for n in 1 2 3 4 5; do used+=(--used "okf/claims/ops-$n.md"); done
for round in 1 2 3; do
  p="$(b pack build "$project_id" --task "ops rule release checklist round $round" --budget-tokens 6000 --receipt | pack_of)"
  b feedback record "$project_id" --pack "${p#"$project_dir/"}" --usefulness useful "${used[@]}" >/dev/null
done
[ "$(usage_of okf/claims/ops-6.md)" = "0 0 3" ] || fail "fixture: ops-6 should be retrieved but never credited: $(usage_of okf/claims/ops-6.md)"
LLM_BRAIN_EXPLORE_MAX_USES=3 b search "$project_id" 'ops rule release checklist' --limit 3 --usage-boost --metadata-file "$fixture/boost.meta" >"$fixture/boost.tsv"
grep -Eq 'okf/claims/ops-[67]\.md' "$fixture/boost.tsv" || fail "rarely credited record crowded out: $(cat "$fixture/boost.tsv")"
grep -Fxq 'diversity_reserved=2' "$fixture/boost.meta" || fail "exploration slots not reserved: $(cat "$fixture/boost.meta")"
LLM_BRAIN_EXPLORE_MAX_USES=0 b search "$project_id" 'ops rule release checklist' --limit 3 --usage-boost >"$fixture/strict.tsv"
! grep -Eq 'okf/claims/ops-[67]\.md' "$fixture/strict.tsv" || fail 'explore-max=0 should restore never-retrieved-only'
checks+=(exploration_for_rarely_retrieved=ok)

# ---- 3. Merge preservation screen.
mkreview() { # id title body extra
  printf -- '---\ntype: ReviewItem\ntitle: "%s"\nbrain_project_id: %s\nbrain_candidate_id: %s\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: internal\nbrain_loading_temperature: warm\nbrain_source_authority: user\nbrain_provider_id: fixture\nbrain_provider_version: "1"\nbrain_provenance: "episode://fixture"\n%sbrain_schema_version: 3\n---\n# %s\n\n%s\n' \
    "$2" "$project_id" "$1" "$4" "$2" "$3" >"$project_dir/review/$1.md"
}
before="$(cat "$claims/port.md" "$claims/region.md" | shasum -a 256)"
mkreview claim_merge_lossy 'Staging deploy summary' 'Staging deploys run behind Caddy in the Sydney region.' $'brain_merge_of: ["okf/claims/port.md", "okf/claims/region.md"]\n'
set +e; out="$(b review decide "$project_id" claim_merge_lossy approved --actor human:test --reason merge 2>&1)"; rc=$?; set -e
[ "$rc" = 75 ] || fail "lossy merge not refused (rc=$rc): $out"
grep -Fq '8443' <<<"$out" && grep -Fq 'ap-southeast-2' <<<"$out" || fail "refusal does not name the lost content: $out"
[ ! -f "$claims/claim_merge_lossy.md" ] || fail 'lossy merge was promoted'
grep -Fq 'brain_review_reason: merge-preservation-failed' "$project_dir/review/claim_merge_lossy.md" || fail 'held review not marked'
grep -Fq 'merge-hold' "$project_dir/audit.v2.tsv" || fail 'merge hold not audited'
checks+=(lossy_merge_refused=ok)

mkreview claim_merge_good 'Staging deploy facts' 'Staging deploys listen on port 8443 behind Caddy, run in ap-southeast-2 on Fridays.' $'brain_merge_of: ["okf/claims/port.md", "okf/claims/region.md"]\n'
b review decide "$project_id" claim_merge_good approved --actor human:test --reason merge >/dev/null || fail 'preserving merge refused'
[ -f "$claims/claim_merge_good.md" ] || fail 'preserving merge not promoted'
grep -Fq 'brain_merge_of' "$claims/claim_merge_good.md" || fail 'merge lineage not kept on the canonical record'
[ "$before" = "$(cat "$claims/port.md" "$claims/region.md" | shasum -a 256)" ] || fail 'originals changed by the merge'
checks+=(preserving_merge_lands_originals_kept=ok)

b review decide "$project_id" claim_merge_lossy approved --actor human:test --reason 'accept the loss' --accept-merge-loss >/dev/null || fail 'override refused'
[ -f "$claims/claim_merge_lossy.md" ] || fail 'override did not promote'
grep -Fq 'merge-loss-accepted' "$project_dir/audit.v2.tsv" || fail 'override not audited'
checks+=(explicit_override_audited=ok)

printf 'memory credit/merge self-check passed: %s\n' "${checks[*]}"
