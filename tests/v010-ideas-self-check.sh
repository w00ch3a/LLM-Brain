#!/usr/bin/env bash
# Self-check for the 0.10 ideas. Each block is tagged with its idea number.
# Every check uses a disposable vault and synthetic records only.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
py="${LLM_BRAIN_OKF_PYTHON:-python3}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-v010.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'v0.10 ideas self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"
workspace="$fixture/workspace"
pid="proj_v010"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$pid" >/dev/null
pdir="$vault/projects/$pid"
claims="$pdir/okf/claims"
b() { (cd "$workspace" && "$cli" --root "$vault" "$@"); }
lineage() { "$py" "$repo_root/lib/memory_lineage.py" "$@"; }
recall_md() { b bridge recall --source-root "$workspace" --project-id "$pid" --query-file "$1" "${@:2}" | "$py" -c 'import json,sys; print(json.load(sys.stdin)["context_markdown"])'; }

claim() { # id title body at [extra frontmatter lines...]
  local id="$1" title="$2" body="$3" at="$4"; shift 4
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $pid" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}

# ---- #1 a '---' inside a frontmatter value or the body is not a delimiter.
mkdir -p "$pdir/sources" "$pdir/indexes"
printf -- '---\ntype: Source\ntitle: "Plan --- draft"\nbrain_observed_at: "2026-01-02T00:00:00Z"\nreviewer_note: frontmatterleak\n---\nThe zircon budget plan is due Friday.\n\n---\n\nAfter the rule: quasar appendix.\n' >"$pdir/sources/abc123def456-plan.md"
printf 'frontmatterleak\n' >"$fixture/q-leak.txt"
printf 'zircon budget plan\n' >"$fixture/q-plan.txt"
! grep -Fq 'abc123def456' <<<"$(recall_md "$fixture/q-leak.txt")" || fail '#1 frontmatter text leaked into the evidence view'
grep -Fq 'quasar appendix' <<<"$(recall_md "$fixture/q-plan.txt")" || fail '#1 body after a --- rule was lost'
! grep -n 'split("---"' "$cli" >/dev/null || fail '#1 an unanchored split("---") remains in the CLI'
rm -rf "$pdir/sources/abc123def456-plan.md" "$pdir/indexes"/evidence-*
printf 'idea-1=ok\n'

# ---- #2 historical/as-of packs label resolver state and order by observed time.
claim tariff-v1 'Tariff rate' 'The tariff rate is 5 percent.' 2026-01-01T00:00:00Z 'brain_observed_at: "2026-01-01T00:00:00Z"'
claim tariff-v2 'Tariff rate (revised)' 'The tariff rate is 7 percent.' 2026-03-01T00:00:00Z 'brain_observed_at: "2026-03-01T00:00:00Z"' 'brain_supersedes: ["okf/claims/tariff-v1.md"]'
pack="$(b pack build "$pid" --task 'tariff rate percent' --historical | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Resolver: HISTORICAL, superseded by `okf/claims/tariff-v2.md` (Tariff rate (revised)) on 2026-03-01' "$pack" || fail "#2 historical label missing: $(cat "$pack")"
grep -Fq 'Resolver: CURRENT as of' "$pack" || fail '#2 current label missing'
[ "$(grep -n '^### Tariff rate' "$pack" | head -1 | cut -d: -f2-)" = '### Tariff rate' ] || fail '#2 not ordered by observed time'
asof="$(b pack build "$pid" --task 'tariff rate percent' --as-of 2026-02-01T00:00:00Z | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'HISTORICAL' "$asof" || fail '#2 as-of pack labelled a record superseded after the as-of date'
plain="$(b pack build "$pid" --task 'tariff rate percent' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Resolver:' "$plain" || fail '#2 default pack gained resolver lines (token cost)'
printf 'idea-2=ok\n'

# ---- #3 session handover: changes since the last session and other agents' work.
claim deploy-new 'Deploy window' 'Deploys happen on Tuesdays.' 2026-05-02T00:00:00Z 'brain_observed_at: "2026-05-02T00:00:00Z"'
brief="$(b brief "$pid" --since 2026-04-01T00:00:00Z)"
grep -Fq 'Since your last session (2026-04-01):' <<<"$brief" || fail "#3 handover heading missing: $brief"
grep -Fq 'new or re-verified: Deploy window' <<<"$brief" || fail '#3 new record missing from handover'
! grep -Fq 'new or re-verified: Tariff rate (revised)' <<<"$brief" || fail '#3 handover listed a change older than --since'
grep -Fq -- '- no approved changes' <<<"$(b brief "$pid" --since 2030-01-01T00:00:00Z --max-bytes 8000)" || fail '#3 empty handover not stated'
! grep -Fq 'Since your last session' <<<"$(b brief "$pid")" || fail '#3 default brief grew a handover without --since'
b working add "$pid" 'Refactor lib/okf.py parser' --session agent:codex >/dev/null
b working add "$pid" 'Tidy lib/okf.py imports' --session agent:hermes >/dev/null
brief="$(b brief "$pid" --session agent:hermes)"
grep -Fq "Other agents' open work here:" <<<"$brief" || fail "#3 other agents section missing: $brief"
grep -Fq '[agent:codex] Refactor lib/okf.py parser' <<<"$brief" || fail '#3 other agent item missing'
grep -Fq 'COLLISION on `lib/okf.py`: agent:codex, agent:hermes' <<<"$brief" || fail '#3 collision not flagged'
# The hook keeps its marker outside the vault and passes --since next time.
hook_state="$fixture/hook-state"
(cd "$workspace" && XDG_STATE_HOME="$hook_state" LLM_BRAIN_ROOT="$vault" sh "$repo_root/hooks/session-start.sh") >/dev/null
[ "$(find "$hook_state/llm-brain/sessions" -type f | wc -l | tr -d ' ')" = 1 ] || fail '#3 hook did not record the session marker'
second="$(cd "$workspace" && XDG_STATE_HOME="$hook_state" LLM_BRAIN_ROOT="$vault" sh "$repo_root/hooks/session-start.sh")"
grep -Fq 'Since your last session' <<<"$second" || fail '#3 hook did not pass --since on the next session'
[ ! -d "$pdir/sessions" ] || fail '#3 handover wrote into the vault'
b working done "$pid" "$(b working list "$pid" | awk -F '\t' 'NR>1 {print $1}' | head -1)" >/dev/null
b working done "$pid" "$(b working list "$pid" | awk -F '\t' 'NR>1 {print $1}' | head -1)" >/dev/null
printf 'idea-3=ok\n'

printf 'v010-ideas-self-check=ok\n'
