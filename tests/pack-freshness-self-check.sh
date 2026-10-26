#!/usr/bin/env bash
# 26 Oct idea 4: a context pack states how fresh its index is:
#   "Index freshness: index as of audit seq N; M captures not yet indexed"
# N is the audit.v2.tsv sequence of the newest index-build row and M the
# ingest-capture rows after it.  LLM_BRAIN_PACK_FRESHNESS=0 turns it off.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-freshness.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'pack freshness self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; pid="proj_fresh"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$pid" >/dev/null
pdir="$vault/projects/$pid"
b() { (cd "$workspace" && "$cli" --root "$vault" "$@"); }
pack_file() { sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
seq_of() { awk -F '\t' 'NR > 1 { n++ } NR > 1 && $3 == "index-build" { s = n } END { print s }' "$pdir/audit.v2.tsv"; }

mkdir -p "$pdir/okf/claims"
cat >"$pdir/okf/claims/deploy.md" <<CLAIM
---
type: Claim
title: "Deploy window rule"
status: stable
generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}
sources: [{resource: "self-check fixture"}]
brain_project_id: $pid
brain_claim_id: deploy
brain_review_state: approved
brain_source_authority: human-directive
brain_sensitivity: internal
brain_schema_version: 3
---
# Deploy window rule

Deploys go out on Tuesdays after the change review.
CLAIM
b index build "$pid" >/dev/null
seq1="$(seq_of)"; [ -n "$seq1" ] || fail 'index build wrote no index-build audit row'
pack="$(b pack build "$pid" --task 'deploy window tuesdays' | pack_file)"
grep -Fxq "Index freshness: index as of audit seq $seq1; 0 captures not yet indexed" "$pack" || fail "fresh pack line missing: $(sed -n 1,40p "$pack")"
grep -Fxq "brain_index_audit_seq: $seq1" "$pack" || fail 'brain_index_audit_seq missing'
grep -Fxq 'brain_unindexed_captures: 0' "$pack" || fail 'brain_unindexed_captures missing'

printf 'note one about release trains\n' >"$fixture/n1.md"
printf 'note two about rollback drills\n' >"$fixture/n2.md"
b ingest-source "$pid" "$fixture/n1.md" >/dev/null
b ingest-source "$pid" "$fixture/n2.md" >/dev/null
pack2="$(b pack build "$pid" --task 'deploy window tuesdays' | pack_file)"
[ "$pack2" != "$pack" ] || fail 'a stale index did not change the pack (idempotency hid the freshness change)'
grep -Fxq "Index freshness: index as of audit seq $seq1; 2 captures not yet indexed" "$pack2" || fail "stale pack line wrong: $(grep -n 'Index freshness' "$pack2" || true)"
grep -Fxq 'brain_unindexed_captures: 2' "$pack2" || fail 'stale count missing from frontmatter'

b index build "$pid" >/dev/null
seq2="$(seq_of)"; [ "$seq2" -gt "$seq1" ] || fail 'second index build did not advance'
pack3="$(b pack build "$pid" --task 'deploy window tuesdays' | pack_file)"
grep -Fxq "Index freshness: index as of audit seq $seq2; 0 captures not yet indexed" "$pack3" || fail 'reindexed pack did not report the new seq'
again="$(b pack build "$pid" --task 'deploy window tuesdays' | pack_file)"
[ "$again" = "$pack3" ] || fail 'unchanged pack is no longer idempotent'

off="$(LLM_BRAIN_PACK_FRESHNESS=0 b pack build "$pid" --task 'deploy window rule' | pack_file)"
! grep -q 'Index freshness\|brain_index_audit_seq' "$off" || fail 'LLM_BRAIN_PACK_FRESHNESS=0 did not turn the line off'
printf 'pack-freshness=ok\n'
