#!/usr/bin/env bash
# #5 (2 Nov ideas): every pack ends with "Returned N of M matching records,
# about T tokens; K lower-ranked and J out of scope omitted."
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-footer.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'pack footer self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_footer"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
claims="$vault/projects/$project_id/okf/claims"
claim() { # id title body at [extra]
  { printf '%s\n' '---' 'type: Claim' "title: \"$2\"" 'status: stable' "generated: {by: \"human:test\", at: \"$4\"}" 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    [ -z "${5:-}" ] || printf '%s\n' "$5"
    printf '%s\n' 'brain_schema_version: 3' '---' "# $2" '' "$3"; } >"$claims/$1.md"
}
for n in $(seq 1 24); do claim "rota-$n" "Ferry rota note $n" "Ferry rota note $n: crew $n covers the harbour ferry rota on shift $n." 2026-09-01T00:00:00Z; done
claim rota-key-old 'Ferry rota lead' 'The ferry rota lead is Kim.' 2026-08-01T00:00:00Z 'brain_state_key: ferry.rota.lead'
claim rota-key-new 'Ferry rota lead now' 'The ferry rota lead is Ari.' 2026-09-05T00:00:00Z 'brain_state_key: ferry.rota.lead'
footer() { grep -E '^Returned [0-9]+ of [0-9]+ matching records' "$1" || true; }
checks=()

p="$("$cli" --root "$vault" pack build "$project_id" --task 'ferry rota' --budget-tokens 300 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
f="$(footer "$p")"; [ -n "$f" ] || fail "no footer: $(tail -5 "$p")"
rendered="$(grep -c '^Expansion: <code>okf/' "$p")"
read -r n m t k j <<<"$(sed -E 's/^Returned ([0-9]+) of ([0-9]+) matching records, about ([0-9]+) tokens; ([0-9]+) lower-ranked and ([0-9]+) out of scope omitted\..*/\1 \2 \3 \4 \5/' <<<"$f")"
[ "$n" = "$rendered" ] || fail "N=$n but $rendered records rendered: $f"
[ "$m" = 26 ] || fail "M should be all 26 matching records: $f"
[ "$j" = 1 ] || fail "the older state value should be the one out-of-scope omission: $f"
[ "$k" = $((m - n - j)) ] || fail "K inconsistent: $f"
[ "$k" -gt 0 ] && grep -Fq 'Ask for more' <<<"$f" || fail "budget-limited pack does not invite a follow-up: $f"
bytes="$(sed -n 's/^Actual bytes: //p' "$p")"; [ "$t" -ge $((bytes / 4)) ] && [ "$t" -le $((bytes / 4 + 1)) ] || fail "token estimate $t vs bytes $bytes"
checks+=(budget_limited_footer=ok)

p="$("$cli" --root "$vault" pack build "$project_id" --task 'ferry rota lead' --budget-tokens 8000 --agent wide | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
f="$(footer "$p")"
n="$(sed -E 's/^Returned ([0-9]+) of.*/\1/' <<<"$f")"; [ "$n" = "$(grep -c '^Expansion: <code>okf/' "$p")" ] || fail "wide pack N wrong: $f"
checks+=(footer_matches_render=ok)
printf 'pack footer self-check passed: %s\n' "${checks[*]}"
