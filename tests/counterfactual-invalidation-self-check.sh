#!/usr/bin/env bash
# #11: before a dependent claim is marked STALE, ask whether it would still
# hold without the invalidated premise.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-cf.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'counterfactual self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; ws="$fixture/ws"; pid=proj_cf; mkdir -p "$ws"
"$cli" --root "$vault" project ensure "$ws" --id "$pid" >/dev/null
claims="$vault/projects/$pid/okf/claims"
claim() {
  local id="$1" at="$2"; shift 2
  { printf '%s\n' '---' 'type: Claim' "title: \"$id\"" 'status: stable' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "fixture"}]'
    printf '%s\n' "brain_project_id: $pid" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $id" '' "Body of $id."; } >"$claims/$id.md"
}
# Premise P is replaced by P2. Four dependents of P:
claim premise 2026-01-01T00:00:00Z 'brain_state_key: build.toolchain'
claim premise-new 2026-02-01T00:00:00Z 'brain_state_key: build.toolchain' 'brain_supersedes: ["okf/claims/premise.md"]'
claim lone-dependent 2026-01-02T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]'
claim backed-dependent 2026-01-02T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]'
claim independent-witness 2026-01-03T00:00:00Z 'brain_supports: ["okf/claims/backed-dependent.md"]'
claim alt-premise 2026-01-03T00:00:00Z
claim listed-dependent 2026-01-02T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]' 'brain_also_supported_by: ["okf/claims/alt-premise.md"]'
claim weak-dependent 2026-01-02T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]' 'brain_dependence: weak'
# A witness that itself depends on the dead premise is not an independent path.
claim tainted-dependent 2026-01-02T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]'
claim tainted-witness 2026-01-03T00:00:00Z 'brain_depends_on: ["okf/claims/premise.md"]' 'brain_supports: ["okf/claims/tainted-dependent.md"]'
claim downstream 2026-01-04T00:00:00Z 'brain_depends_on: ["okf/claims/lone-dependent.md"]'
claim downstream-of-kept 2026-01-04T00:00:00Z 'brain_depends_on: ["okf/claims/backed-dependent.md"]'

plan="$("$cli" --root "$vault" invalidate preview "$pid" --from okf/claims/premise-new.md)"
row() { awk -F '\t' -v r="okf/claims/$1.md" '$1 == r { print $2; exit }' <<<"$plan"; }
[ "$(row premise)" = REPLACE ] || fail "premise not REPLACE: $plan"
[ "$(row lone-dependent)" = STALE ] || fail "lone dependent not STALE: $plan"
[ "$(row downstream)" = STALE ] || fail "cascade through a stale dependent broke: $plan"
[ "$(row backed-dependent)" = KEEP ] || fail "independently supported dependent not KEEP: $plan"
grep -q 'counterfactual: still holds without okf/claims/premise.md via okf/claims/independent-witness.md' <<<"$plan" || fail "KEEP reason missing: $plan"
[ "$(row listed-dependent)" = KEEP ] || fail "alternative premise ignored: $plan"
[ "$(row weak-dependent)" = UNKNOWN ] || fail "weak dependence not UNKNOWN: $plan"
[ "$(row tainted-dependent)" = STALE ] || fail "a witness on the same dead premise counted as independent: $plan"
[ -z "$(row downstream-of-kept)" ] || fail "a kept record must not cascade: $plan"
echo "counterfactual_plan=ok"
# The old behaviour is one switch away, for comparison.
old="$(LLM_BRAIN_COUNTERFACTUAL=0 "$cli" --root "$vault" invalidate preview "$pid" --from okf/claims/premise-new.md)"
[ "$(awk -F '\t' '$2 == "STALE"' <<<"$old" | wc -l)" -gt "$(awk -F '\t' '$2 == "STALE"' <<<"$plan" | wc -l)" ] || fail "opt-out did not restore the old plan"
echo "stale_before=$(awk -F '\t' '$2 == "STALE"' <<<"$old" | wc -l) stale_after=$(awk -F '\t' '$2 == "STALE"' <<<"$plan" | wc -l)"
echo "counterfactual-invalidation self-check passed"
