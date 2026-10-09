#!/usr/bin/env bash
# Neural Expansion viewer: synthetic-only shipping, adapter filtering, CLI
# gating and the offline page contract.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
home="$repo_root/neural-expansion"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-neural-expansion.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'neural expansion self-check: %s\n' "$*" >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

for file in "$home"/build_demo.py "$home"/bench.py "$home"/adapter/*.py "$home"/tests/*.py; do
  python3 - "$file" <<'PY' || fail "not parseable: $file"
import ast, sys
ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])
PY
done
python3 -m unittest discover -s "$home/tests" >"$fixture/unittest.log" 2>&1 || { cat "$fixture/unittest.log" >&2; fail 'adapter/demo unit tests failed'; }
if command -v node >/dev/null 2>&1; then
  node --test "$home/tests/viewer_logic.test.cjs" >"$fixture/node.log" 2>&1 || { cat "$fixture/node.log" >&2; fail 'viewer logic tests failed'; }
else
  printf '%s\n' 'neural expansion self-check: node unavailable; viewer logic tests skipped' >&2
fi

# Only synthetic data ships: no data/output directories, OS junk or generated real pages.
for unwanted in data output .DS_Store; do
  [ -z "$(find "$home" -name "$unwanted" -print -quit)" ] || fail "unexpected $unwanted in neural-expansion"
done
[ -z "$(find "$home" -name '._*' -print -quit)" ] || fail 'AppleDouble files shipped'
[ "$(find "$home/demo" -type f | wc -l | tr -d ' ')" = 1 ] || fail 'demo must contain only the synthetic page'
grep -Fq '"privacy": "Synthetic only"' "$home/fixtures/synthetic.json" || fail 'fixture is not marked synthetic'
if LC_ALL=C grep -R -nE '/Users/|/Volumes/|/home/[A-Za-z]|(^|[^0-9])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+\.[0-9]+' "$home"; then
  fail 'personal path or private address in neural-expansion'
fi

# CLI: synthetic demo and path.
demo_path="$("$cli" neural-expansion path)"
[ "$demo_path" = "$home/demo/neural-expansion-synthetic.html" ] || fail "unexpected demo path: $demo_path"
"$cli" viewer demo --output "$fixture/demo.html" | grep -Fq 'data=synthetic' || fail 'demo build did not report synthetic data'
cmp -s "$fixture/demo.html" "$demo_path" || fail 'committed demo is stale; run build_demo.py'
grep -Fq '<title>LLM-Brain · Neural Expansion</title>' "$fixture/demo.html" || fail 'Neural Expansion title missing'
grep -Fq "connect-src 'none'" "$fixture/demo.html" || fail 'network content policy missing'
if "$cli" viewer demo --output "$fixture/demo.html" >/dev/null 2>&1; then fail 'demo overwrote an existing file'; fi

# Real-data export is opt-in, principal-filtered, private and outside the vault.
vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_neural_expansion_self_check"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
claims="$vault/projects/$project_id/okf/claims"
write_claim() {
  local id="$1" title="$2" body="$3" extra="${4:-}"
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
write_claim shared 'Shared design note' 'Shared synthetic note; see [[Team note]].'
write_claim team 'Team note' 'Team synthetic note.' 'brain_principal: alice'
write_claim hidden 'Hidden note' 'Bob-only synthetic marker text.' 'brain_principal: bob'
"$cli" --root "$vault" index build "$project_id" >/dev/null
if "$cli" --root "$vault" neural-expansion export "$project_id" --principal alice --output "$fixture/page.html" >/dev/null 2>&1; then
  fail 'export ran without the experimental opt-in'
fi
[ ! -e "$fixture/page.html" ] || fail 'gated export wrote a file'
LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 "$cli" --root "$vault" neural-expansion export "$project_id" --principal alice --output "$fixture/page.html" >/dev/null
[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$fixture/page.html")" = 0o600 ] || fail 'export is not owner-only'
grep -Fq 'Shared design note' "$fixture/page.html" || fail 'visible record missing from export'
grep -Fq 'Team note' "$fixture/page.html" || fail 'principal-scoped record missing for its principal'
! grep -Fq 'Bob-only synthetic marker' "$fixture/page.html" || fail 'hidden record body leaked'
! grep -Fq 'Hidden note' "$fixture/page.html" || fail 'hidden record title leaked'
if LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 "$cli" --root "$vault" neural-expansion export "$project_id" --principal alice --output "$vault/inside.html" >/dev/null 2>&1; then
  fail 'export wrote inside the vault'
fi
if LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 "$cli" --root "$vault" neural-expansion export "$project_id" --principal alice --output "$fixture/page.html" >/dev/null 2>&1; then
  fail 'export overwrote an existing file'
fi
mkdir -p "$vault/.locks/project-$project_id.lock"
if LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 "$cli" --root "$vault" neural-expansion export "$project_id" --principal alice --output "$fixture/locked.html" >/dev/null 2>&1; then
  fail 'export ran while a writer lock was present'
fi
rmdir "$vault/.locks/project-$project_id.lock"

printf '%s\n' 'llm-brain neural expansion self-check passed'
