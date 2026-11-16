#!/usr/bin/env bash
# #2 (16 Nov ideas): each lesson has a share scope (this-agent / this-owner /
# all-agents).  A planted owner-only fact never reaches another principal or
# agent through search, packs, recall, briefs, exports or replication, and
# `share audit` probes for leaks.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-share-scope.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_SHARE_SCOPE_ENFORCE LLM_BRAIN_OWNER_PRINCIPAL LLM_BRAIN_STRICT_PRINCIPAL LLM_BRAIN_AGENT_IDENTITY LLM_BRAIN_HOST
fail() { printf 'share scope self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; ws="$fixture/ws"; mkdir -p "$ws"; project_id="proj_share"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
mkreview() { # id title body [extra frontmatter lines]
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: ReviewItem' "title: \"$title\"" "brain_project_id: $project_id" "brain_candidate_id: $id" 'brain_review_kind: claim' 'brain_review_state: proposed' 'brain_confidence: 0.9' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_loading_temperature: warm' 'brain_source_authority: user' 'brain_provider_id: fixture' 'brain_provider_version: "1"' 'brain_provenance: "episode://fixture"'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$pdir/review/$id.md"
}
decide() { set +e; out="$(b review decide "$project_id" "$1" approved --actor human:test --reason fixture "${@:2}" 2>&1)"; rc=$?; set -e; }
checks=()

mkreview ads_bank 'Garden gate code' 'The garden gate code for Ads is kingfisher-417.'
decide ads_bank --share-scope this-owner --share-owner ads; [ "$rc" = 0 ] || fail "this-owner promote: $out"
mkreview codex_fmt 'Garden repo formatter' 'In the garden repo, Codex runs make fmt before each commit.'
decide codex_fmt --share-scope this-agent --share-owner ads --share-agent codex; [ "$rc" = 0 ] || fail "this-agent promote: $out"
mkreview ferry 'Garden ferry time' 'The garden island ferry leaves at 9.'
decide ferry --share-scope all-agents; [ "$rc" = 0 ] || fail "all-agents promote: $out"
mkreview manny_pref 'Garden tea' 'Manny takes garden mint tea without sugar.' 'brain_principal: manny'
decide manny_pref; [ "$rc" = 0 ] || fail "principal lesson promote: $out"
grep -q '^brain_share_scope: this-owner$' "$claims/ads_bank.md" && grep -q '^brain_share_owner: "ads"$' "$claims/ads_bank.md" || fail 'this-owner not stamped'
grep -q '^brain_share_scope: this-agent$' "$claims/codex_fmt.md" && grep -q '^brain_share_agent: "codex"$' "$claims/codex_fmt.md" || fail 'this-agent not stamped'
grep -q '^brain_share_scope: all-agents$' "$claims/ferry.md" || fail 'all-agents not stamped'
grep -q '^brain_share_scope: this-owner$' "$claims/manny_pref.md" && grep -q '^brain_share_owner: "manny"$' "$claims/manny_pref.md" || fail 'captured principal not narrowed by default'
grep -q 'share-scope-set' "$pdir/audit.v2.tsv" || fail 'share scope not audited'
checks+=(scopes_stamped=ok)

mkreview oo_note 'Garden alarm' 'The garden alarm is disarmed from the shed.' 'brain_owner_only: true'
decide oo_note --share-scope all-agents
[ "$rc" = 65 ] && [ ! -f "$claims/oo_note.md" ] || fail "owner-only lesson shared with all agents (rc=$rc): $out"
decide oo_note --share-scope this-owner --share-owner ads; [ "$rc" = 0 ] || fail "owner-only this-owner promote: $out"
# A planted owner-only record with no share scope at all (hand-written).
printf '%s\n' '---' 'type: Claim' 'title: "Garden safe"' 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" 'brain_claim_id: planted' 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_owner_only: true' 'brain_schema_version: 3' '---' '# Garden safe' '' 'The garden safe is behind the potting bench.' >"$claims/planted.md"
checks+=(owner_only_never_all_agents=ok)

q='garden gate code repo formatter ferry tea alarm safe'
pack() { b pack build "$project_id" --task "$q" --budget-tokens 4000 "$@" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
has() { grep -Fq "$2" "$1"; }
# Another owner (Manny), any agent.
for ag in generic codex hermes; do
  p="$(pack --principal manny --agent "$ag")"
  ! has "$p" kingfisher-417 || fail "Ads's this-owner fact leaked to manny ($ag)"
  ! has "$p" 'make fmt' || fail "this-agent lesson leaked to manny ($ag)"
  ! has "$p" 'disarmed from the shed' || fail "owner-only lesson leaked to manny ($ag)"
  ! has "$p" 'potting bench' || fail "planted owner-only record leaked to manny ($ag)"
  has "$p" 'leaves at 9' && has "$p" 'mint tea' || fail "manny lost shared/own lessons ($ag)"
done
# The owner, as the right and the wrong agent.
p="$(pack --principal ads --agent codex)"
has "$p" kingfisher-417 && has "$p" 'make fmt' && has "$p" 'leaves at 9' || fail 'owner as codex missing own lessons'
! has "$p" 'mint tea' || fail "manny's lesson leaked to ads"
p="$(pack --principal ads --agent hermes)"
has "$p" kingfisher-417 || fail 'owner lost this-owner lesson as hermes'
! has "$p" 'make fmt' || fail 'codex-only lesson leaked to hermes'
p="$(pack)"
has "$p" kingfisher-417 || fail 'unnamed owner caller lost this-owner lesson'
! has "$p" 'make fmt' || fail 'this-agent lesson shown to an unknown agent'
checks+=(packs_scoped=ok)

# Search, recall (Hermes bridge), brief.
s="$(b search "$project_id" "$q" --principal manny)"
! grep -Eq 'ads_bank|codex_fmt|oo_note|planted' <<<"$s" || fail "search leaked to manny: $s"
printf '%s\n' "$q" >"$fixture/query.txt"
r="$(LLM_BRAIN_HOST=hermes b bridge recall --source-root "$ws" --project-id "$project_id" --query-file "$fixture/query.txt" --strategy lexical --principal manny)"
! grep -Eq 'kingfisher-417|make fmt|disarmed|potting bench' <<<"$r" || fail 'recall leaked to manny'
grep -Fq 'leaves at 9' <<<"$r" || fail "recall lost the shared lesson: $r"
bd="$(b brief "$project_id" --principal manny --max-bytes 20000 2>/dev/null || true)"
! grep -Eq 'kingfisher-417|make fmt|disarmed|potting bench' <<<"$bd" || fail 'brief leaked to manny'
checks+=(search_recall_brief_scoped=ok)

# Nothing owner- or agent-only leaves the brain.
b export knowledge-catalog "$project_id" >/dev/null
cat_dir="$pdir/exports/knowledge-catalog/documents/claims"
[ -f "$cat_dir/ferry.md" ] || fail 'shared lesson missing from catalog export'
for f in ads_bank codex_fmt oo_note planted manny_pref; do [ ! -f "$cat_dir/$f.md" ] || fail "$f exported in catalog"; done
b export bundle "$project_id" >/dev/null
listing="$(tar -tzf "$pdir/exports/${project_id}-okf.tar.gz")"
grep -q 'claims/ferry.md' <<<"$listing" || fail 'shared lesson missing from bundle'
! grep -Eq 'claims/(ads_bank|codex_fmt|oo_note|planted|manny_pref)\.md' <<<"$listing" || fail "owner-only lesson in bundle"
b export replication "$project_id" --output "$fixture/repl.tar.gz" >/dev/null
listing="$(tar -tzf "$fixture/repl.tar.gz")"
grep -q 'claims/ferry.md' <<<"$listing" || fail "shared lesson missing from replication: $listing"
! grep -Eq 'claims/(ads_bank|codex_fmt|oo_note|planted|manny_pref)\.md' <<<"$listing" || fail 'owner-only lesson in replication archive'
grep -q '"share-scope-this-agent"\|"owner-only"\|visibility-scope' "$fixture/repl.tar.gz.manifest.json" || fail 'replication manifest does not record the exclusions'
checks+=(exports_exclude=ok)

# The probe: no leaks now; with enforcement switched off it catches them.
out="$(b share audit "$project_id" --as manny --as hermes:default --agent hermes)" || fail "share audit reported leaks: $out"
grep -q 'leaks=0' <<<"$out" && grep -q 'records=5' <<<"$out" || fail "audit summary wrong: $out"
set +e; out="$(LLM_BRAIN_SHARE_SCOPE_ENFORCE=0 b share audit "$project_id" --as manny --agent hermes)"; rc=$?; set -e
[ "$rc" = 1 ] && grep -q 'leak	okf/claims/ads_bank.md	manny' <<<"$out" || fail "probe missed a leak with enforcement off (rc=$rc): $out"
! grep -Fq 'kingfisher' <<<"$out" || fail 'audit printed record content'
checks+=(leak_probe=ok)
printf 'share scope self-check passed: %s\n' "${checks[*]}"
