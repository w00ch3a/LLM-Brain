#!/usr/bin/env bash
# bridge_sources_meta (one awk pass) and the cached variant must produce
# exactly the rows the former per-file frontmatter_field loop produced, in the
# same order, across cold/warm cache, edits, deletions and new views.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-evidence-meta.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'evidence-meta: %s\n' "$*" >&2; exit 1; }

eval "$(sed -n '/^frontmatter_field() {/,/^}/p' "$cli")"
eval "$(sed -n '/^bridge_sources_meta() {/,/^}/p' "$cli")"
eval "$(sed -n '/^bridge_cached_sources_meta() {/,/^}/p' "$cli")"
eval "$(grep '^EVIDENCE_SOURCES_META_HEADER=' "$cli")"
EVIDENCE_VIEW_VERSION="$(sed -n 's/^EVIDENCE_VIEW_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$cli" | head -1)"
[ -n "$EVIDENCE_VIEW_VERSION" ] || fail "EVIDENCE_VIEW_VERSION not found"

dir="$fixture/project"; mkdir -p "$dir/sources" "$dir/indexes/evidence-text"
w() { printf '%b' "$2" >"$dir/sources/$1"; }
w aaa111-plain.md '---\ntype: Source\ntitle: "Plain: with colon"\nbrain_principal: hermes:default\nbrain_observed_at: "2026-01-02T00:00:00Z"\n---\n# body\ntitle: not header\n'
w bbb222-noheader.md '# No frontmatter\ntitle: body only\n'
w ccc333-dup.md '---\ntitle: first\ntitle: second\nbrain_principal:   spaced   \n---\n'
w ddd444-unterminated.md '---\ntitle: never closed\nbrain_observed_at: 2025-05-05\n'
w eee555-empty.md ''
w fff666.md '---\nbrain_principal: "quoted"\n---\nbrain_principal: body\n'
: >"$dir/indexes/evidence-text/aaa111-${EVIDENCE_VIEW_VERSION}.txt"
printf 'x\n' >"$dir/indexes/evidence-text/ccc333-${EVIDENCE_VIEW_VERSION}.txt"

reference() {
find "$dir/sources" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort >"$fixture/list"
while IFS= read -r file; do
  rel="${file#"$dir"/}"; source_hash="${rel##*/}"; source_hash="${source_hash%%-*}"
  view="$dir/indexes/evidence-text/${source_hash}-${EVIDENCE_VIEW_VERSION}.txt"; [ -f "$view" ] && view="${view#"$dir"/}" || view=""
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$(frontmatter_field "$file" brain_principal)" "$(frontmatter_field "$file" brain_observed_at)" "$(frontmatter_field "$file" title)" "$view" "$source_hash"
done <"$fixture/list" >"$fixture/expected"
}
check_cached() {
  reference
  bridge_cached_sources_meta "$dir" "$fixture/list" >"$fixture/cached"
  diff -u "$fixture/expected" "$fixture/cached" || fail "cached metadata differs ($1)"
  [ "$(head -1 "$dir/indexes/evidence-sources-meta.tsv")" = "$EVIDENCE_SOURCES_META_HEADER" ] || fail "cache not written ($1)"
}
reference
bridge_sources_meta "$dir" "$fixture/list" >"$fixture/actual"
diff -u "$fixture/expected" "$fixture/actual" || fail "single-pass metadata differs from frontmatter_field loop"
[ "$(wc -l <"$fixture/actual" | tr -d ' ')" = 6 ] || fail "expected one row per source"
: >"$fixture/empty-list"
[ -z "$(bridge_sources_meta "$dir" "$fixture/empty-list")" ] || fail "empty list produced rows"
check_cached cold
check_cached warm
# A warm cache must not reopen unchanged sources: poison one cached title and
# confirm the cache (not the file) is used, then edit the file to invalidate.
sed -i.bak 's/Plain: with colon/CACHED/' "$dir/indexes/evidence-sources-meta.tsv"; rm -f "$dir/indexes/evidence-sources-meta.tsv.bak"
touch -t 202001010000 "$dir/sources/aaa111-plain.md"
reference; bridge_cached_sources_meta "$dir" "$fixture/list" | grep -q 'CACHED' || fail "warm cache reopened an unchanged source"
sleep 1; printf '%b' '---\ntitle: Edited title\n---\n' >"$dir/sources/aaa111-plain.md"
check_cached edited
grep -q 'Edited title' "$fixture/cached" || fail "edited source not refreshed"
rm -f "$dir/sources/ccc333-dup.md"; check_cached deleted
printf 'v\n' >"$dir/indexes/evidence-text/fff666-${EVIDENCE_VIEW_VERSION}.txt"; check_cached new-view
w ggg777-new.md '---\ntitle: Added later\n---\n'; check_cached added
printf 'garbage\n' >"$dir/indexes/evidence-sources-meta.tsv"; check_cached foreign-cache
printf 'evidence-meta-self-check=ok\n'
