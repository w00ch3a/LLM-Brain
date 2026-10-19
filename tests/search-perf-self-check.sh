#!/usr/bin/env bash
# Search must not start one process per record: eligibility, the canonical
# signature and BM25F come from one `memory_signals search-prepare` pass,
# result rows come from one `okf facts-list` call, and file hashes are
# batched. This guard counts helper starts (load-independent) and checks that
# the fast path, the old batched path (search-prepare unavailable) and the
# per-file fallback (no batch helpers at all) return byte-identical results
# with the same filtering.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-search-perf.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$fixture"' EXIT
fail() { printf 'search perf self-check: %s\n' "$*" >&2; exit 1; }

workspace="$fixture/workspace"; vault="$fixture/vault"; project_id=proj_search_perf_test
mkdir -p "$workspace"
git -C "$workspace" init -q
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims" "$project/okf/retractions"

claim() {
  local id="$1" title="$2" extra="${3:-}"
  {
    printf -- '---\ntype: Claim\ntitle: %s\nstatus: stable\nbrain_project_id: %s\nbrain_claim_id: %s\n' "$title" "$project_id" "$id"
    printf 'brain_review_state: approved\nbrain_sensitivity: internal\nbrain_source_authority: repository\nbrain_schema_version: 3\n'
    [ -z "$extra" ] || printf '%b\n' "$extra"
    printf -- '---\n# %s\n\nSynthetic harbour ferry timetable record %s about tides and ferry docking.\n' "$title" "$id"
  } >"$project/okf/claims/$id.md"
}
for n in $(seq -w 1 24); do claim "ferry-$n" "Ferry timetable $n"; done
claim ferry-restricted "Ferry restricted" 'brain_loading_temperature: warm\nsensitivity_note: x' 
sed -i.bak 's/^brain_sensitivity: internal$/brain_sensitivity: restricted/' "$project/okf/claims/ferry-restricted.md"
claim ferry-cold "Ferry cold" 'brain_loading_temperature: cold'
claim ferry-expired "Ferry expired" 'brain_valid_to: 2001-01-01T00:00:00Z'
claim ferry-old "Ferry old timetable"
claim ferry-new "Ferry new timetable" 'brain_supersedes: ferry-old'
claim ferry-retracted "Ferry retracted"
printf -- '---\ntype: Retraction\nstatus: stable\n---\n# Synthetic retraction\n' >"$project/okf/retractions/ferry-retracted.md"
rm -f "$project/okf/claims/"*.bak

embedder="$fixture/embedder"
cat >"$embedder" <<'EMB'
#!/usr/bin/env python3
import sys
text = open(sys.argv[1], encoding="utf-8").read().lower()
vec = [text.count(c) + 1 for c in "aeiou"]
print("model: synthetic-vowels")
print("dimensions: 5")
print("vector: " + " ".join(str(v) for v in vec))
EMB
chmod +x "$embedder"
LLM_BRAIN_EMBEDDER_VERSION=v1 "$cli" --root "$vault" index build "$project_id" --embedder "$embedder" >/dev/null

real_python="$(command -v python3)"
wrapper="$fixture/python-counter"
cat >"$wrapper" <<'WRAPPER'
#!/bin/bash
printf '%s\n' "${2:-}" >>"$SEARCH_PERF_LOG"
case "${SEARCH_PERF_BREAK:-}:${2:-}" in
  prepare:search-prepare|all:search-prepare|all:valid-batch|all:facts-list) exit 1 ;;
esac
exec "$SEARCH_PERF_REAL_PYTHON" "$@"
WRAPPER
chmod +x "$wrapper"

run_search() {
  local tag="$1" strategy="$2"; shift 2
  : >"$fixture/$tag.log"
  SEARCH_PERF_LOG="$fixture/$tag.log" SEARCH_PERF_REAL_PYTHON="$real_python" LLM_BRAIN_OKF_PYTHON="$wrapper" \
    "$cli" --root "$vault" search "$project_id" "ferry timetable tides" --limit 40 --strategy "$strategy" \
    --query-embedder "$embedder" --explain --metadata-file "$fixture/$tag.meta" "$@" >"$fixture/$tag.out"
}

same_results() {
  local base="$1" other="$2" what="$3"
  cmp -s "$fixture/$base.out" "$fixture/$other.out" || fail "$what: results differ"
  cmp -s "$fixture/$base.meta" "$fixture/$other.meta" || fail "$what: metadata differ"
}
count() { grep -c "^$1\$" "$fixture/$2.log" || true; }

for strategy in hybrid lexical; do
  # Index build refuses malformed YAML, so add the invalid record (duplicate
  # key) after the hybrid pass; lexical BM25F reads canonical files directly.
  [ "$strategy" != lexical ] || claim ferry-malformed "Ferry malformed" 'brain_sensitivity: internal'
  run_search "$strategy" "$strategy"
  SEARCH_PERF_BREAK=prepare run_search "$strategy-batch" "$strategy"
  SEARCH_PERF_BREAK=all run_search "$strategy-fallback" "$strategy"
  same_results "$strategy" "$strategy-batch" "$strategy: fast and batched paths"
  same_results "$strategy" "$strategy-fallback" "$strategy: fast and per-file paths"
  [ "$(count search-prepare "$strategy")" = 1 ] || fail "$strategy: expected exactly one search-prepare call"
  for helper in valid-batch bm25 field facts; do
    [ "$(count "$helper" "$strategy")" = 0 ] || fail "$strategy: fast path started okf/memory_signals $helper"
  done
  [ "$(count valid-batch "$strategy-batch")" = 1 ] || fail "$strategy: batched path did not use valid-batch"
  [ "$(count field "$strategy-batch")" = 0 ] || fail "$strategy: batched path validated per file"
  [ "$(count field "$strategy-fallback")" -gt 0 ] || fail "$strategy: fallback did not validate per file"
  [ "$(count facts "$strategy-fallback")" -gt 0 ] || fail "$strategy: fallback did not read facts per row"
  results="$(tail -n +2 "$fixture/$strategy.out" | wc -l | tr -d ' ')"
  starts="$(wc -l <"$fixture/$strategy.log" | tr -d ' ')"
  # search-prepare + facts-list: a fixed count, not one per record or row
  [ "$starts" -le 2 ] || fail "$strategy: $starts Python starts for $results results"
  for excluded in ferry-malformed ferry-restricted ferry-cold ferry-expired ferry-old ferry-retracted; do
    ! grep -q "okf/claims/$excluded.md" "$fixture/$strategy.out" || fail "$strategy: $excluded should be filtered"
  done
  grep -q 'okf/claims/ferry-new.md' "$fixture/$strategy.out" || fail "$strategy: ferry-new missing"
  for n in $(seq -w 1 24); do grep -q "okf/claims/ferry-$n.md" "$fixture/$strategy.out" || fail "$strategy: ferry-$n missing"; done
done

# A value search-prepare cannot judge byte-for-byte (non-ASCII edge) must be
# handed back to the shell check for that record, with identical results.
claim ferry-unsure "Ferry unsure timetable" "brain_loading_temperature: caf\\303\\251"
run_search unsure lexical
SEARCH_PERF_BREAK=all run_search unsure-fallback lexical
same_results unsure unsure-fallback "unsure record: fast and per-file paths"
[ "$(count search-prepare unsure)" = 1 ] || fail "unsure record: search-prepare not tried"
[ "$(count bm25 unsure)" = 1 ] || fail "unsure record: BM25F was not rescored after the shell check"
grep -q '^retrieval_mode=hybrid-rrf$' "$fixture/hybrid.meta" || fail "hybrid search degraded"
printf 'search perf self-check passed\n'
