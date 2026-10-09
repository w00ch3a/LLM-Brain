#!/usr/bin/env bash
# Corrections and retractions must reach the agent even when they share no
# words with the task, with the corrected value and the notice's source ID
# intact, and without disclosing retracted/superseded content or hidden
# records.  Keyword intentions must match simple inflections.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-research-recall.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'research-recall: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; work="$fixture/work"; mkdir -p "$work"
pid=proj_recall
lb() { (cd "$work" && "$cli" --root "$vault" "$@"); }
lb project ensure "$work" --id "$pid" >/dev/null
claims="$vault/projects/$pid/okf/claims"
claim() { # id title text [extra frontmatter lines...]
  local id="$1" title="$2" text="$3"; shift 3
  { printf -- '---\ntype: Claim\ntitle: "%s"\nstatus: stable\ngenerated: {by: "human:test", at: "2026-01-01T00:00:00Z"}\n' "$title"
    printf 'sources: [{resource: "test notes"}]\nbrain_project_id: %s\nbrain_review_state: approved\nbrain_source_authority: human-directive\nbrain_sensitivity: internal\n' "$pid"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'brain_schema_version: 3\n---\n# %s\n\n%s\n' "$title" "$text"; } >"$claims/$id.md"
}
claim pilot-14 "Pilot run length" "Pilot units ran 14 months without failure (DOC-3)." 'brain_observed_at: "2025-09-30T00:00:00Z"'
claim pilot-11 "Pilot run length (corrected)" "Correction: erratum DOC-10 corrects DOC-3. The pilot units ran 11 months, not 14." 'brain_observed_at: "2026-01-20T00:00:00Z"' 'brain_supersedes: pilot-14'
claim cell-88 "Cell cold retention" "Cells retain 88% capacity at -20 C (DOC-4)."
claim decision "Working recommendation" "Adopt chemistry A for the deployment."
claim hidden-old "Private figure" "Private secret value 42." 'brain_principal: "alice"'
claim hidden-new "Private figure (corrected)" "Correction: the private value is 43." 'brain_supersedes: hidden-old' 'brain_principal: "alice"'
preview="$(lb retract "$pid" cell-88 --reason "DOC-4 retracted by the journal (notice DOC-9)." --preview)"
token="$(printf '%s\n' "$preview" | sed -n 's/.*token=\([0-9a-f]\{64\}\).*/\1/p')"
lb retract "$pid" cell-88 --reason "DOC-4 retracted by the journal (notice DOC-9)." --confirm "$token" >/dev/null
lb intention add "$pid" --action "List open question Q-3 in any recommendation." --trigger keyword:recommendation >/dev/null
lb index build "$pid" >/dev/null

brief="$(lb brief "$pid")"
printf '%s\n' "$brief" | grep -q '^Corrections and retractions' || fail "brief lacks corrections section"
printf '%s\n' "$brief" | grep -q '11 months, not 14' || fail "brief dropped the corrected value"
printf '%s\n' "$brief" | grep -q 'retracted Cell cold retention (cell-88): DOC-4 retracted by the journal (notice DOC-9)' || fail "brief retraction lacks title/reason"
printf '%s\n' "$brief" | grep -q 'outrank it, except where memory records a later correction' || fail "brief header not updated"
printf '%s\n' "$brief" | grep -q 'Private figure' && fail "brief disclosed a principal-scoped record"

pack="$(lb pack build "$pid" --task "recommend a deployment" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$pack" ] || fail "pack not built"
grep -q '^## Corrections and Retractions' "$pack" || fail "pack lacks corrections section"
grep -q 'ran 11 months, not 14' "$pack" || fail "pack lacks correction text"
grep -q 'notice DOC-9' "$pack" || fail "pack lacks retraction notice id"
grep -q 'Replaces: Pilot run length (2025-09-30)' "$pack" || fail "pack lacks superseded pointer"
grep -q 'retain 88%' "$pack" && fail "pack disclosed retracted content"
grep -q 'ran 14 months without' "$pack" && fail "pack disclosed superseded content"
grep -q 'Private\|secret value' "$pack" && fail "pack disclosed a principal-scoped record"
grep -q 'keyword-stem~recommendation' "$pack" || fail "keyword intention did not match 'recommend'"

# The principal that can see the scoped records gets their correction.
py="${LLM_BRAIN_OKF_PYTHON:-python3}"
notices="$("$py" "$repo_root/lib/memory_signals.py" notices --project-dir "$vault/projects/$pid" --principal alice)"
printf '%s\n' "$notices" | grep -q 'private value is 43' || fail "scoped correction hidden from its principal"
notices="$("$py" "$repo_root/lib/memory_signals.py" notices --project-dir "$vault/projects/$pid" --principal bob)"
printf '%s\n' "$notices" | grep -q 'Private' && fail "scoped correction shown to another principal"
# Limit is honoured.
[ "$("$py" "$repo_root/lib/memory_signals.py" notices --project-dir "$vault/projects/$pid" --limit 1 | wc -l | tr -d ' ')" = 1 ] || fail "notice limit ignored"
printf 'research-recall-self-check=ok\n'
