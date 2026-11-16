#!/usr/bin/env bash
# #4 (16 Nov ideas): part of the pack budget is held for open conflicts that
# touch the query, so a tight budget cannot cut them first.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-conflict-reserve.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PACK_CONFLICT_RESERVE
fail() { printf 'conflict reserve self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_reserve"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$fixture/ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
claim() { # id title other body
  printf '%s\n' '---' 'type: Claim' "title: \"$2\"" 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' ${3:+"brain_conflicts: [okf/claims/$3.md]"} 'brain_schema_version: 3' '---' "# $2" '' "$4" >"$claims/$1.md"
}
for i in 1 2 3 4 5 6 7 8; do
  claim "note-$i" "Deploy region runbook part $i" '' "$(for j in $(seq 1 9); do printf 'Deploy region runbook step %s.%s: check the deploy region dashboard, deploy region alarms and deploy region quotas before the rollout. ' "$i" "$j"; done)"
done
claim region-a 'Region (desk note)' region-b 'Production deploys go to ap-southeast-2.'
claim region-b 'Region (ops sheet)' region-a 'Production deploys go to us-east-1.'
task='deploy region'
pack() { b pack build "$project_id" --task "$1" --agent "a$RANDOM" --budget-tokens "$2" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
both() { grep -Fq 'ap-southeast-2' "$1" && grep -Fq 'us-east-1' "$1"; }
checks=()

# 1. Without the reserve (0.13 behaviour) a tight budget cuts the conflict.
p0="$(LLM_BRAIN_PACK_CONFLICT_RESERVE=0 pack "$task" 300)"
! grep -Fq 'ap-southeast-2' "$p0" && ! grep -Fq 'us-east-1' "$p0" || fail 'fixture does not reproduce the cut (conflict fit without a reserve)'
checks+=(cut_without_reserve=ok)

# 2. With the default 20% reserve both sides are kept, labelled, in budget.
p="$(pack "$task" 300)"
both "$p" || fail "conflict sides missing with the reserve: $(grep -c '^### ' "$p") records"
grep -Fq 'Open conflict: <code>okf/claims/region-a.md</code>' "$p" || fail 'conflict not labelled'
grep -Fq 'Conflict reserve: 20% of the budget held for open conflicts; 2 conflicting record(s) shown.' "$p" || fail "reserve footer missing: $(grep -F 'Conflict reserve' "$p" || true)"
grep -q '^brain_open_conflicts: 2$' "$p" || fail 'frontmatter lacks open conflict count'
bytes="$(sed -n 's/^Actual bytes: //p' "$p")"; [ "$bytes" -le 1200 ] || fail "pack over budget: $bytes bytes"
grep -q '^### Deploy region runbook part 1$' "$p" || fail 'top-ranked record lost'
checks+=(reserve_keeps_both_sides=ok)

# 3. One side matching the query brings the other side with it.
p="$(pack 'ap-southeast-2 production deploys' 300)"
both "$p" || fail 'partner side not brought in'
checks+=(partner_brought_in=ok)

# 4. Detection across budgets (the paper's finding, on this fixture).
old=0; new=0; n=0
for budget in 150 200 250 300 350 400 500 600; do
  n=$((n + 1))
  both "$(LLM_BRAIN_PACK_CONFLICT_RESERVE=0 pack "$task" "$budget")" && old=$((old + 1)) || true
  both "$(pack "$task" "$budget")" && new=$((new + 1)) || true
done
printf 'conflict detection over %s budgets: reserve=0 %s/%s, reserve=20%% %s/%s\n' "$n" "$old" "$n" "$new" "$n"
[ "$new" = "$n" ] && [ "$old" -lt "$n" ] || fail "reserve did not raise detection ($old -> $new of $n)"
checks+=(detection_over_budgets=ok)

# 5. A decided conflict is not open: no reserve, same as without it.
b conflict decide "$project_id" region-a region-b --winner b --reason 'ops sheet is authoritative' >/dev/null
p="$(pack "$task" 300)"
! grep -Fq 'Conflict reserve' "$p" || fail 'decided conflict still reserved'
checks+=(decided_not_reserved=ok)

# 6. No open conflict: the pack is the 0.13 pack (same selection hash).
rm -rf "$pdir/conflict-decisions"; sed -i '/^brain_conflicts:/d' "$claims/region-a.md" "$claims/region-b.md"
p1="$(b pack build "$project_id" --task "$task" --agent same --budget-tokens 300)"
p2="$(LLM_BRAIN_PACK_CONFLICT_RESERVE=0 b pack build "$project_id" --task "$task" --agent same --budget-tokens 300)"
grep -q '^pack=idempotent' <<<"$p2" || fail "pack without conflicts changed: $p1 / $p2"
checks+=(no_conflict_unchanged=ok)
printf 'conflict reserve self-check passed: %s\n' "${checks[*]}"
