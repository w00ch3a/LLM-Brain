#!/usr/bin/env bash
# 26 Oct idea 3: a retraction finishes properly.
#   * retract --source REF drops one receipt; another independent source keeps
#     the claim active and its folder summary is rebuilt;
#   * a full retraction purges query logs / pack receipts / feedback text
#     (ids and the tombstone stay), deletes the record's embeddings, and fails
#     closed naming any derived store that did not update (here: a registered
#     Neural Expansion export page that still carries the record).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-retract-complete.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'retract complete self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; pid="proj_retract"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$pid" >/dev/null
pdir="$vault/projects/$pid"; claims="$pdir/okf/claims"; mkdir -p "$claims"
b() { (cd "$workspace" && "$cli" --root "$vault" "$@"); }
found() { local out; out="$(b search "$pid" "$1")"; printf '%s\n' "$out" | grep -Fq "$2"; }
claim() { # id title body [extra frontmatter...]
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $pid" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
claim walrus 'Walrus migration timing' 'Walrus herds migrate north in late spring.' 'brain_source_ref: "doc:alpha"'
claim walrus-survey 'Walrus survey note' 'The 2025 survey also saw walrus herds migrate north.' 'brain_source_ref: "doc:beta"' 'brain_supports: okf/claims/walrus.md'
claim penguin 'Penguin colony size' 'Penguin colonies number in the thousands.' 'brain_source_ref: "doc:gamma"'
b index build "$pid" >/dev/null
b summaries build "$pid" >/dev/null 2>&1 || "${LLM_BRAIN_OKF_PYTHON:-python3}" "$repo_root/lib/memory_lineage.py" summaries --project-dir "$pdir" --action build >/dev/null
[ -d "$pdir/indexes/summaries" ] || fail 'folder summaries were not built'

# ---- receipt mode: a non-backing source is refused
set +e; out="$(b retract "$pid" walrus --source doc:nope --reason 'bad source' --preview 2>&1)"; rc=$?; set -e
[ "$rc" = 65 ] || fail "non-backing source exit $rc: $out"
printf '%s' "$out" | grep -Fq 'source does not back this claim' || fail "non-backing message: $out"
set +e; out="$(b retract "$pid" walrus --source doc:alpha --reason x 2>&1)"; rc=$?; set -e
[ "$rc" = 64 ] || fail "--source without preview/confirm exit $rc"

# ---- receipt mode: doc:alpha is dropped, doc:beta still backs the claim
preview="$(b retract "$pid" walrus --source doc:alpha --reason 'alpha doc withdrawn' --preview)"
printf '%s' "$preview" | grep -Fq 'mode=receipt' || fail "receipt preview: $preview"
printf '%s' "$preview" | grep -Fq 'remaining_sources=1' || fail "receipt preview remaining: $preview"
token="$(printf '%s' "$preview" | sed -n 's/.* token=\([0-9a-f]*\).*/\1/p' | head -n1)"
out="$(b retract "$pid" walrus --source doc:alpha --reason 'alpha doc withdrawn' --confirm "$token")"
printf '%s' "$out" | grep -Fq 'claim_state=active' || fail "receipt apply: $out"
[ ! -f "$pdir/okf/retractions/walrus.md" ] || fail 'receipt mode wrote a full tombstone'
receipt_tomb="$(ls "$pdir"/okf/retractions/receipts/walrus--src-*.md)"
grep -Fq 'brain_retracts_source: "doc:alpha"' "$receipt_tomb" || fail 'receipt tombstone lacks the source'
grep -q '^brain_retracts:' "$receipt_tomb" && fail 'receipt tombstone must not retract the claim'

found 'walrus migrate north' 'claims/walrus.md' || fail 'receipt-retracted claim left search'
grep -rFq 'walrus.md) (1 source retracted)' "$pdir/indexes/summaries" || fail 'folder summary was not rebuilt for the dropped receipt'
grep -Fq $'\tretract-source\t' "$pdir/audit.v2.tsv" || fail 'retract-source audit row missing'
# same source again: no longer backs
set +e; b retract "$pid" walrus --source doc:alpha --reason again --preview >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 65 ] || fail "re-retracting a dropped source exit $rc"

# ---- full retraction: query logs, receipts, feedback, embeddings, exports
pack="$(b pack build "$pid" --task 'walrus migrate north' --receipt | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -n "$pack" ] && grep -Fq 'walrus' "$pack" || fail 'pack did not select the walrus claim'
pack_ref="${pack#"$pdir"/}"
b search "$pid" 'walrus migrate north' --receipt >/dev/null
b feedback record "$pid" --pack "$pack_ref" --usefulness useful --notes 'walrus herds migrate north, very helpful' >/dev/null
receipts="$pdir/audit/retrieval-receipts.jsonl"
grep -Fq 'okf/claims/walrus.md' "$receipts" || fail 'fixture receipts did not log the claim'
ids_before="$(grep -o '"receipt_id": *"[0-9a-f]*"' "$receipts" | sort)"
walrus_hash="$(sha256sum "$claims/walrus.md" | cut -d' ' -f1)"
mkdir -p "$pdir/indexes/embeddings"
printf '0.1 0.2\n' >"$pdir/indexes/embeddings/${walrus_hash}-fake-v1.txt"
printf '0.3 0.4\n' >"$pdir/indexes/embeddings/other-fake-v1.txt"
export_page="$fixture/exports/brain.html"; mkdir -p "$(dirname "$export_page")"
printf '<html>Walrus migration timing okf/claims/walrus.md</html>\n' >"$export_page"
printf 'exported_at\tprincipal\toutput\n2026-10-26T00:00:00Z\tself\t%s\n' "$export_page" >"$pdir/audit/neural-expansion-exports.tsv"

preview="$(b retract "$pid" walrus --source doc:beta --reason 'beta also withdrawn' --preview)"
printf '%s' "$preview" | grep -Fq 'retraction_mode=full' || fail "last source should fall through to full: $preview"
token="$(printf '%s' "$preview" | sed -n 's/.* token=\([0-9a-f]*\).*/\1/p' | head -n1)"
set +e; out="$(b retract "$pid" walrus --source doc:beta --reason 'beta also withdrawn' --confirm "$token" 2>&1)"; rc=$?; set -e
[ "$rc" = 75 ] || fail "stale export should fail closed (exit $rc): $out"
printf '%s' "$out" | grep -Fq 'retraction_apply=incomplete' || fail "incomplete line missing: $out"
printf '%s' "$out" | grep -Fq 'derived stores not updated: neural-expansion-export' || fail "failed store not named: $out"
[ -f "$pdir/okf/retractions/walrus.md" ] || fail 'tombstone missing after incomplete retraction'
found 'walrus migrate north' 'claims/walrus.md' && fail 'fully retracted claim still searchable'

# purged: query logs / pack receipts keep ids, lose content
grep -Fq 'okf/claims/walrus.md' "$receipts" && fail 'receipts still reference the retracted record'
grep -Fq '"purged_for": "walrus"' "$receipts" || fail 'receipts were not marked purged'
[ "$(grep -o '"receipt_id": *"[0-9a-f]*"' "$receipts" | sort)" = "$ids_before" ] || fail 'receipt ids changed'
grep -rFq 'very helpful' "$pdir/feedback" && fail 'feedback text not purged'
grep -rFq 'brain_purged_for: walrus' "$pdir/feedback" || fail 'feedback not marked purged'
grep -rFq "Pack: \`$pack_ref\`" "$pdir/feedback" || fail 'feedback lost its pack id'
[ ! -e "$pdir/indexes/embeddings/${walrus_hash}-fake-v1.txt" ] || fail 'retracted embedding kept'
[ -e "$pdir/indexes/embeddings/other-fake-v1.txt" ] || fail 'unrelated embedding removed'
grep -rFq '(walrus.md)' "$pdir/indexes/summaries" && fail 'folder summary still lists the retracted record'

# re-check after the stale page is gone: finish reports every store ok
rm -f "$export_page"
out="$(b retract "$pid" walrus --finish)"
printf '%s' "$out" | grep -Fq 'retraction_finish=ok' || fail "finish: $out"
for store in receipts feedback embeddings search-index folder-summary neural-expansion-export; do
  printf '%s' "$out" | grep -Fq "derived_store=$store state=ok" || fail "store $store not ok: $out"
done
found 'penguin colonies' 'claims/penguin.md' || fail 'unrelated claim lost'
lint_out="$("$cli" --root "$vault" lint --project "$pid" 2>&1 || true)"; printf "%s" "$lint_out" | grep -Eq "errors=0|lint=ok" || fail "OKF lint failed after retraction: $lint_out"
printf 'retract-complete=ok\n'
