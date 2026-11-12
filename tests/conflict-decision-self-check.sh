#!/usr/bin/env bash
# #7 (2 Nov ideas): a conflict decision is its own record tied to both sides'
# hashes; it re-opens when either side is edited or retracted.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-conflict-decision.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'conflict decision self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_ferry"
lb() { "$cli" --root "$vault" "$@"; }
lb project ensure "$fixture/ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
claim() { # id title other body
  printf '%s\n' '---' 'type: Claim' "title: \"$2\"" 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' ${3:+"brain_conflicts: [okf/claims/$3.md]"} 'brain_schema_version: 3' '---' "# $2" '' "$4" >"$claims/$1.md"
}
claim fee-a 'Ferry fee (desk note)' fee-b 'The ferry fee is 5 dollars.'
claim fee-b 'Ferry fee (operator site)' fee-a 'The ferry fee is 7 dollars.'
claim timetable 'Ferry timetable' '' 'The ferry leaves at 9.'
state_of() { lb search "$project_id" 'ferry fee' | awk -F '\t' -v p="okf/claims/$1.md" '$1 == p { print $4 }'; }
pack() { lb pack build "$project_id" --task 'ferry fee' --agent "$1" ${2:+--intent "$2"} | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
checks=()

[ "$(state_of fee-a)" = approved-conflicted ] && [ "$(state_of fee-b)" = approved-conflicted ] || fail "fixture pair is not conflicted"
lb conflict decide "$project_id" fee-a timetable --winner a --reason x 2>/dev/null && fail "decision on a pair that has no conflict was accepted" || [ $? = 65 ] || fail "wrong exit for non-conflict"
lb conflict decide "$project_id" fee-a fee-b --winner c --reason x 2>/dev/null && fail "bad --winner accepted"
out="$(lb conflict decide "$project_id" fee-a fee-b --winner b --reason 'operator site is authoritative')"
id="$(sed -n 's/.*decision_id=\([^ ]*\).*/\1/p' <<<"$out")"
dfile="$pdir/conflict-decisions/$id.md"; [ -f "$dfile" ] || fail "decision is not its own record: $out"
grep -q "^brain_conflict_a_sha256: $(sha256sum "$claims/fee-a.md" | cut -d' ' -f1)$" "$dfile" || fail "decision not tied to side A hash"
grep -q "^brain_conflict_b_sha256: $(sha256sum "$claims/fee-b.md" | cut -d' ' -f1)$" "$dfile" || fail "decision not tied to side B hash"
grep -q "conflict-decided" "$pdir/audit.v2.tsv" || fail "decision not audited"
grep -q 'brain_conflicts' "$claims/fee-a.md" || fail "decision must not rewrite the records themselves"
checks+=(decision_record=ok)

[ "$(state_of fee-b)" = approved ] || fail "winner still conflicted: $(state_of fee-b)"
[ "$(state_of fee-a)" = approved-conflicted ] || fail "loser should stay flagged: $(state_of fee-a)"
p="$(pack valid current_state)"
grep -Fq '`okf/claims/fee-b.md` wins over `okf/claims/fee-a.md`' "$p" || fail "pack lacks decision line"
grep -Fq 'okf/claims/fee-a.md` (historical:conflict-decided-against)' "$p" || fail "loser not resolved as historical in current_state pack"
lb conflict list "$project_id" | grep -q "^$id"$'\t'"valid"$'\t' || fail "list does not show valid"
checks+=(valid_decision_applies=ok)

printf '\nRechecked in November.\n' >>"$claims/fee-b.md"
lb conflict list "$project_id" | grep -q "^$id"$'\t'"reopened"$'\t'.*'fee-b.md was edited after the decision' || fail "edit did not re-open: $(lb conflict list "$project_id")"
[ "$(state_of fee-b)" = approved-conflicted ] || fail "edited winner kept its win"
p="$(pack edited)"
grep -Fq 'RE-OPENED' "$p" && grep -Fq 'fee-b.md was edited after the decision' "$p" || fail "pack does not say the decision re-opened"
checks+=(edit_reopens=ok)

out="$(lb conflict decide "$project_id" fee-a fee-b --winner b --reason 'rechecked operator site')"
id2="$(sed -n 's/.*decision_id=\([^ ]*\).*/\1/p' <<<"$out")"
[ "$id2" != "$id" ] && [ ! -f "$dfile" ] && [ -f "$pdir/conflict-decisions/replaced/$id.md" ] || fail "re-decision did not replace the stale decision"
[ "$(state_of fee-b)" = approved ] || fail "re-decision not applied"
token="$(lb retract "$project_id" fee-b --reason 'operator page was wrong' --preview 2>&1 | sed -n 's/.*token=\([0-9a-f]*\).*/\1/p')"
lb retract "$project_id" fee-b --reason 'operator page was wrong' --confirm "$token" >/dev/null 2>&1
lb conflict list "$project_id" | grep -q "^$id2"$'\t'"reopened"$'\t'.*'fee-b.md was retracted' || fail "retraction did not re-open: $(lb conflict list "$project_id")"
checks+=(retraction_reopens=ok)
printf 'conflict decision self-check passed: %s\n' "${checks[*]}"
