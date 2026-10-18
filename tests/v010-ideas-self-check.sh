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

printf 'v010-ideas-self-check=ok\n'
