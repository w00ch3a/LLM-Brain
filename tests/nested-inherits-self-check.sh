#!/usr/bin/env bash
# #6 (2 Nov ideas): a folder registered as a nested project inside a parent
# repository is its own boundary; parent memory reaches it only through a
# declared `inherits:` and is rendered in its own labelled section.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-nested.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'nested inherits self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; parent="$fixture/mono"; child="$parent/apps/kiosk"
mkdir -p "$child/src/deep" "$parent/tools"
git -C "$parent" init -q
git -C "$parent" remote add origin https://example.invalid/mono.git
lb() { "$cli" --root "$vault" "$@"; }
detect_id() { lb --cwd "$1" detect | sed -n 's/^project_id=//p'; }
claim() { # project id title body
  local claims="$vault/projects/$1/okf/claims"
  { printf '%s\n' '---' 'type: Claim' "title: \"$3\"" 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $1" "brain_claim_id: $2" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_schema_version: 3' '---' "# $3" '' "$4"; } >"$claims/$2.md"
}
pack() { lb pack build "$1" --task 'release checklist' --budget-tokens 2000 ${2:+--agent "$2"} | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
checks=()

lb project ensure "$parent" --id proj_mono >/dev/null
[ "$(detect_id "$child/src/deep")" = proj_mono ] || fail "before registration the child folder should belong to the parent repo"
lb project ensure "$child" --id proj_kiosk 2>/dev/null && fail "plain registration inside a parent repo should still conflict"
lb project ensure "$child" --id proj_kiosk --nested >/dev/null
[ "$(detect_id "$child")" = proj_kiosk ] || fail "nested root does not resolve to its own project"
[ "$(detect_id "$child/src/deep")" = proj_kiosk ] || fail "subfolder of nested root does not resolve to it"
[ "$(detect_id "$parent/tools")" = proj_mono ] || fail "unregistered parent subfolder no longer resolves to the parent"
[ "$(detect_id "$parent")" = proj_mono ] || fail "parent root moved"
checks+=(nested_boundary=ok)

claim proj_mono mono-release 'Release checklist for the monorepo' 'Release checklist: sign every tag with the PARENTSIGN key before pushing.'
claim proj_kiosk kiosk-release 'Release checklist for the kiosk app' 'Release checklist: run make kiosk-image and attach the KIOSKIMG artefact.'

p="$(pack proj_kiosk)"
grep -Fq KIOSKIMG "$p" || fail "child pack lost its own record"
! grep -Fq PARENTSIGN "$p" || fail "parent memory leaked into a child that did not declare inherits"
! grep -Fq 'Inherited from' "$p" || fail "inherited section without a declaration"
checks+=(no_leak_without_inherits=ok)

lb project ensure "$child" --id proj_kiosk --nested --inherits proj_nope 2>/dev/null && fail "unknown inherited project accepted"
lb project ensure "$child" --id proj_kiosk --nested --inherits proj_kiosk 2>/dev/null && fail "self-inheritance accepted"
out="$(lb project ensure "$child" --id proj_kiosk --nested --inherits proj_mono)"
grep -Fq 'inherits=proj_mono' <<<"$out" || fail "ensure did not report inherits: $out"
grep -q '^brain_inherits: proj_mono$' "$vault/projects/proj_kiosk/okf/index.md" || fail "brain_inherits not declared in index"
grep -q project-inherits "$vault/projects/proj_kiosk/audit.v2.tsv" || fail "inherits declaration not audited"
checks+=(declaration_recorded=ok)

q="$(pack proj_kiosk second)"
grep -Fq 'Inherited from `proj_mono`' "$q" || fail "declared inherit not rendered: $(cat "$q")"
grep -Fq PARENTSIGN "$q" || fail "inherited parent record missing"
grep -Fq 'Expansion: <code>proj_mono:okf/claims/mono-release.md</code>' "$q" || fail "inherited record not labelled with its parent ref"
grep -q '^brain_inherits: proj_mono$' "$q" || fail "pack metadata lacks brain_inherits"
own_line="$(grep -n KIOSKIMG "$q" | head -1 | cut -d: -f1)"; inh_line="$(grep -n 'Inherited from' "$q" | cut -d: -f1)"
[ "$own_line" -lt "$inh_line" ] || fail "inherited section rendered before the child's own records"
checks+=(declared_inherit_rendered=ok)

r="$(pack proj_mono)"
! grep -Fq KIOSKIMG "$r" || fail "child memory leaked upward into the parent"
checks+=(no_upward_leak=ok)
printf 'nested inherits self-check passed: %s\n' "${checks[*]}"
