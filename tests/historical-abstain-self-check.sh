#!/usr/bin/env bash
# #13 (11 Nov ideas): an as-of pack uses only records written by that date as
# evidence, says per state key whether that evidence settles one value, and
# tells the agent to abstain when it does not.  A later record that matches
# the question is left out rather than used to fill the gap.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hist-abstain.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'historical abstain self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_hist_abstain"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
claims="$vault/projects/$project_id/okf/claims"
b() { "$cli" --root "$vault" "$@"; }
claim() {
  local id="$1" title="$2" body="$3" at="$4"; shift 4
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
pack_at() { b pack build "$project_id" --task "$1" --as-of "$2" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
field() { awk -v k="$1:" '$1 == k { print $2; exit }' "$2"; }

claim region-v1 'Deploy region: Sydney' 'The deploy region is Sydney.' 2026-03-01T00:00:00Z 'brain_state_key: deploy.region'
claim region-v2 'Deploy region: Singapore' 'The deploy region is Singapore.' 2026-06-01T00:00:00Z 'brain_state_key: deploy.region' 'brain_supersedes: ["okf/claims/region-v1.md"]'
claim quota 'Deploy quota' 'The deploy quota is 40 builds.' 2026-02-01T00:00:00Z 'brain_state_key: deploy.quota' 'brain_valid_to: 2026-04-01T00:00:00Z'

checks=()
# 1. Between the two values: v1 settles it, v2 (written later) is absent.
pack="$(pack_at 'deploy region' 2026-04-15T00:00:00Z)"
[ -f "$pack" ] || fail 'as-of pack not built'
grep -Fq 'State `deploy.region`: determined by `okf/claims/region-v1.md`' "$pack" || fail "region not determined by v1: $(cat "$pack")"
! grep -Fq 'Singapore' "$pack" || fail 'a later record leaked into the as-of pack'
grep -Fq 'written after this date were left out' "$pack" || fail 'hidden later record not counted'
[ "$(field brain_historical_sufficiency "$pack")" = determined ] || fail 'metadata not determined'
checks+=(determined_without_future=ok)

# 2. Before anything was recorded: abstain, and do not reveal either value.
pack="$(pack_at 'deploy region' 2026-01-15T00:00:00Z)"
grep -Fq 'State `deploy.region`: NOT determined' "$pack" || fail "no abstention before first record: $(cat "$pack")"
grep -Fq 'nothing about it was recorded by this date' "$pack" || fail 'reason missing'
grep -Fq 'Abstain' "$pack" || fail 'abstain instruction missing'
! grep -Eq 'Sydney|Singapore' "$pack" || fail 'pack revealed a value recorded after the as-of date'
[ "$(field brain_historical_sufficiency "$pack")" = insufficient ] || fail 'metadata not insufficient'
checks+=(abstain_before_first_record=ok)

# 3. The only value had expired by the date: abstain rather than reuse it.
pack="$(pack_at 'deploy quota builds' 2026-05-01T00:00:00Z)"
grep -Fq 'State `deploy.quota`: NOT determined' "$pack" || fail "expired value treated as determined: $(cat "$pack")"
grep -Fq 'had expired' "$pack" || fail 'expiry reason missing'
checks+=(abstain_after_expiry=ok)

# 4. After the supersession: v2 determines it.
pack="$(pack_at 'deploy region' 2026-07-01T00:00:00Z)"
grep -Fq 'State `deploy.region`: determined by `okf/claims/region-v2.md`' "$pack" || fail "post-supersession not v2: $(cat "$pack")"
checks+=(determined_after_supersession=ok)

# 5. Packs without --as-of are unchanged: no sufficiency section, metadata none.
pack="$(b pack build "$project_id" --task 'deploy region' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Historical Sufficiency' "$pack" || fail 'current pack gained a sufficiency section'
[ "$(field brain_historical_sufficiency "$pack")" = none ] || fail 'current pack metadata not none'
checks+=(current_pack_unchanged=ok)

printf 'historical abstain self-check passed: %s\n' "${checks[*]}"
