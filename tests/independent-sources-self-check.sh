#!/usr/bin/env bash
# #4 (2 Nov ideas): count independent original sources, not voices.  Five
# sessions or agents repeating a claim are one source; the same document cited
# twice is one source.  Packs never present a mention count as support.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="${LLM_BRAIN_TEST_CLI:-$repo_root/bin/llm-brain}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-indep.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PACK_ACTION_RISK MEMTHENA_PACK_ACTION_RISK LLM_BRAIN_PACK_SOURCE_COUNT
fail() { printf 'independent sources self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_indep"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"; mkdir -p "$project/okf/claims"
claim() { # id title sources body
  {
    printf '%s\n' '---' 'type: Claim' "title: $2" 'status: stable' 'generated: {by: process:test, at: 2026-08-07T00:00:00Z}' "sources: $3"
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal'
    printf '%s\n' 'brain_source_authority: repository' 'brain_provenance: human://fixture' 'brain_schema_version: 3' '---' "# $2" '' "$4"
  } >"$project/okf/claims/$1.md"
}
claim claim_echo 'Ferry gate echo' '[{resource: "session:a1"}, {resource: "session:b2"}, {resource: "agent:planner"}, {resource: "agent:reviewer"}, {resource: "episode://e9"}]' 'The ferry gate closes at noon.'
claim claim_dupe 'Ferry gate dupe' '[{resource: "https://docs.example.invalid/ferry"}, {resource: "https://docs.example.invalid/ferry/"}, {resource: "https://docs.example.invalid/ferry#hours"}]' 'The ferry gate opens at six.'
claim claim_two 'Ferry gate two' '[{resource: "https://docs.example.invalid/ferry"}, {resource: "https://ops.example.invalid/gates"}]' 'The ferry gate is owned by ops.'
claim claim_mixed 'Ferry gate mixed' '[{resource: "https://ops.example.invalid/gates"}, {resource: "session:c3"}, {resource: "session:d4"}]' 'The ferry gate has a backup key.'
"$cli" --root "$vault" index build "$project_id" >/dev/null
high="$("$cli" --root "$vault" pack build "$project_id" --task 'ferry gate' --action-risk high --budget-tokens 4000 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
block() { awk -v t="$1" '/^### /{ on = (index($0, t) > 0) } on' "$high"; }
checks=()
block 'Ferry gate echo' | grep -Fq 'Action risk: <code>re-verify before acting</code> (single-source)' || fail "five voices treated as several sources: $(block 'Ferry gate echo')"
block 'Ferry gate echo' | grep -Fq 'Independent sources: <code>1</code> (5 agent/session mentions count as one)' || fail "voice count not collapsed: $(block 'Ferry gate echo')"
checks+=(voices_count_once=ok)
block 'Ferry gate dupe' | grep -Fq '(single-source)' || fail 'same document cited three ways counted as several'
checks+=(same_document_once=ok)
! block 'Ferry gate two' | grep -Fq 're-verify before acting' || fail 'two independent documents flagged'
block 'Ferry gate two' | grep -Fq 'Independent sources: <code>2</code>' || fail 'two documents not counted as two'
block 'Ferry gate mixed' | grep -Fq 'Independent sources: <code>2</code>' || fail 'document + conversation not counted as two'
checks+=(independent_documents_counted=ok)
! grep -Eiq '[0-9]+ (agents|sessions) (said|agree|confirmed)' "$high" || fail 'pack presents a voice count as support'
checks+=(no_voice_count_as_trust=ok)
printf 'independent sources self-check passed: %s\n' "${checks[*]}"
