#!/usr/bin/env bash
# #10: a record rewritten after it changed underneath is refused (exit 75),
# the newer file is left intact, and each refused writer keeps its version
# at its own fork path.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-stale.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
vault="$fixture/vault"; ws="$fixture/ws"; mkdir -p "$ws"
export LLM_BRAIN_LOCK_WAIT_SECONDS=30 LLM_BRAIN_LOCK_POLL_SECONDS=1 LLM_BRAIN_REVIEW_POLICY=strict
"$cli" --root "$vault" project ensure "$ws" --id proj_stale >/dev/null
printf '# Note\n\nThe kettle is blue.\n' >"$fixture/note.md"
"$cli" --root "$vault" ingest-source proj_stale "$fixture/note.md" >/dev/null
review="$(ls "$vault/projects/proj_stale/review/"source_*.md)"
id="$(basename "$review" .md)"

# 1. Unchanged record: decide works as before, no fork.
cp "$review" "$fixture/review.orig"
"$cli" --root "$vault" review decide proj_stale "$id" needs-validation --reason first >/dev/null
grep -q '^brain_review_state: needs-validation$' "$review"
! ls "$review".conflict-* >/dev/null 2>&1
echo "unchanged_write=ok"

# 2. Another machine edits the record while a decide is in flight.
LLM_BRAIN_DEBUG_WRITE_DELAY=2 "$cli" --root "$vault" review decide proj_stale "$id" rejected --reason stale >"$fixture/a.out" 2>"$fixture/a.err" & pid=$!
sleep 1
printf '\nHuman note added on another machine.\n' >>"$review"
cp "$review" "$fixture/review.human"
rc=0; wait "$pid" || rc=$?
[ "$rc" = 75 ] || { echo "expected 75, got $rc"; cat "$fixture/a.err"; exit 1; }
grep -q 'stale write refused' "$fixture/a.err"
cmp -s "$review" "$fixture/review.human" || { echo "newer record was overwritten"; exit 1; }
forks=( "$review".conflict-* ); [ "${#forks[@]}" = 1 ] && [ -f "${forks[0]}" ]
grep -q '^brain_review_state: rejected$' "${forks[0]}"
! grep -q 'Human note' "${forks[0]}"
echo "stale_write_refused=ok"

# 3. Two more stale writers: each keeps its own fork, none clobbered.
for n in 2 3; do
  LLM_BRAIN_DEBUG_WRITE_DELAY=2 "$cli" --root "$vault" review decide proj_stale "$id" superseded --reason "stale-$n" >/dev/null 2>&1 & p=$!
  sleep 1; printf 'edit %s\n' "$n" >>"$review"; wait "$p" || true
done
forks=( "$review".conflict-* ); [ "${#forks[@]}" = 3 ] || { echo "expected 3 forks, got ${#forks[@]}"; exit 1; }
# The first fork still holds writer 1's decision; the later two hold theirs.
[ "$(grep -l '^brain_review_state: rejected$' "${forks[@]}" | wc -l)" = 1 ]
[ "$(grep -l '^brain_review_state: superseded$' "${forks[@]}" | wc -l)" = 2 ]
grep -q 'edit 3' "$review" && grep -q 'Human note' "$review"
echo "distinct_forks=ok"

# 4. Forks are never loaded as memory.
listing="$("$cli" --root "$vault" review list proj_stale)"
[ "$(printf '%s\n' "$listing" | tail -n +2 | wc -l)" = 1 ] || { echo "fork listed as a review: $listing"; exit 1; }
case "$listing" in *conflict-*) echo "fork listed"; exit 1 ;; esac
echo "forks_not_records=ok"
echo "stale-write self-check passed"
