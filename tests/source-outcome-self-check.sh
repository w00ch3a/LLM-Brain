#!/usr/bin/env bash
# #5 (16 Nov ideas): lessons carry the outcome of the task they were learnt
# from (brain_source_outcome: success|failure|unknown); packs and recall flag
# failure-derived or conflicting lessons "check evidence before acting" with
# the evidence path.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-source-outcome.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PACK_EVIDENCE_FLAGS
fail() { printf 'source outcome self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; ws="$fixture/ws"; mkdir -p "$ws"; project_id="proj_outcome"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
mkreview() { # id title body [extra frontmatter lines]
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: ReviewItem' "title: \"$title\"" "brain_project_id: $project_id" "brain_candidate_id: $id" 'brain_review_kind: claim' 'brain_review_state: proposed' 'brain_confidence: 0.9' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_loading_temperature: warm' 'brain_source_authority: user' 'brain_provider_id: fixture' 'brain_provider_version: "1"'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$pdir/review/$id.md"
}
decide() { set +e; out="$(b review decide "$project_id" "$1" approved --actor human:test --reason fixture "${@:2}" 2>&1)"; rc=$?; set -e; [ "$rc" = 0 ] || fail "promote $1 (rc=$rc): $out"; }
episode_id() { sed -n 's/^brain_episode_id: //p' "$(sed -n 's/.*episode=\([^ ]*\).*/\1/p' <<<"$1" | head -n 1)"; }
checks=()

# Two captured tasks: one failed, one succeeded (adapter-declared outcome).
printf '%s\n' '---' 'type: HermesTurn' 'title: "Migration attempt"' 'brain_task_outcome: failed' '---' 'Tried the cache migration with --batch 500; it timed out.' >"$fixture/fail.md"
printf '%s\n' '---' 'type: HermesTurn' 'title: "Cache resize"' 'brain_task_outcome: success' '---' 'Resized the cache to 50 GB; checks green.' >"$fixture/ok.md"
fe="$(episode_id "$(b ingest-source "$project_id" "$fixture/fail.md")")"
se="$(episode_id "$(b ingest-source "$project_id" "$fixture/ok.md")")"
grep -rq '^brain_task_outcome: failure$' "$pdir/episodes" || fail 'failed task outcome not on the episode'
checks+=(episode_outcome=ok)

mkreview lesson_batch 'Cache migration batch size' 'Run the cache migration with batch size 500.' "brain_provenance: \"episode://$fe\""
mkreview lesson_resize 'Cache resize size' 'The cache should be 50 GB.' "brain_provenance: \"episode://$se\""
mkdir -p "$pdir/runs/outcomes"
printf '%s\n' '---' 'type: ProcedureOutcome' 'title: "Outcome run1"' "brain_project_id: $project_id" 'brain_run_id: run1' 'brain_outcome_id: outcome_x' 'brain_outcome_status: partial' 'brain_schema_version: 3' '---' '# Procedure outcome' >"$pdir/runs/outcomes/outcome_x.md"
mkreview lesson_restart 'Cache restart order' 'Restart the cache workers before the web tier.' 'brain_provenance: "episode://none"' 'brain_outcome_ref: "runs/outcomes/outcome_x.md"'
mkreview lesson_plain 'Cache owner' 'The cache is owned by the platform team.' 'brain_provenance: "episode://none"'
mkreview lesson_manual 'Cache eviction' 'Cache eviction runs at 02:00.' 'brain_provenance: "episode://none"'
for r in lesson_batch lesson_resize lesson_restart lesson_plain; do decide "$r"; done
decide lesson_manual --source-outcome failure
want() { grep -q "^brain_source_outcome: $2$" "$claims/$1.md" || fail "$1 outcome: $(grep -E 'brain_source_(outcome|evidence)' "$claims/$1.md" || echo none)"; }
want lesson_batch failure; want lesson_resize success; want lesson_restart failure; want lesson_plain unknown; want lesson_manual failure
grep -q '^brain_source_evidence: "episodes/.*\.md"$' "$claims/lesson_batch.md" || fail 'episode evidence path not recorded'
grep -q '^brain_source_evidence: "runs/outcomes/outcome_x.md"$' "$claims/lesson_restart.md" || fail 'run outcome evidence path not recorded'
grep -q 'source-outcome-set' "$pdir/audit.v2.tsv" || fail 'manual outcome not audited'
checks+=(lessons_stamped=ok)

# A conflicting pair (no outcome) is flagged too.
printf '%s\n' '---' 'type: Claim' 'title: "Cache region A"' 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" 'brain_claim_id: reg-a' 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_conflicts: [okf/claims/reg-b.md]' 'brain_schema_version: 3' '---' '# Cache region A' '' 'The cache lives in region A.' >"$claims/reg-a.md"
sed -e 's/reg-a/reg-x/; s/Cache region A/Cache region B/g; s/region A/region B/; s#okf/claims/reg-b.md#okf/claims/reg-a.md#; s/reg-x/reg-b/' "$claims/reg-a.md" >"$claims/reg-b.md"

task='cache migration batch size resize restart owner eviction region'
p="$(b pack build "$project_id" --task "$task" --budget-tokens 4000 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
section() { awk -v t="### $1" '$0 == t { on=1; next } on && /^### / { exit } on' "$p"; }
section 'Cache migration batch size' | grep -Fq 'Check evidence before acting: it was learnt from a task that failed. Evidence: `episodes/' || fail "failure lesson not flagged: $(section 'Cache migration batch size')"
section 'Cache restart order' | grep -Fq 'Evidence: `runs/outcomes/outcome_x.md`' || fail 'partial-run lesson not flagged with its outcome'
section 'Cache region A' | grep -Fq 'Check evidence before acting: it conflicts with another record' || fail 'conflicting lesson not flagged'
for t in 'Cache resize size' 'Cache owner'; do ! section "$t" | grep -Fq 'Check evidence' || fail "$t flagged without cause"; done
checks+=(pack_flags=ok)

printf '%s\n' "$task" >"$fixture/q.txt"
r="$(b bridge recall --source-root "$ws" --project-id "$project_id" --query-file "$fixture/q.txt" --strategy lexical --budget-tokens 4000)"
grep -Fq 'Check evidence before acting: it was learnt from a task that failed' <<<"$r" || fail 'recall lacks the flag'
checks+=(recall_flags=ok)

p="$(LLM_BRAIN_PACK_EVIDENCE_FLAGS=0 b pack build "$project_id" --task "$task" --agent off --budget-tokens 4000 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Check evidence before acting' "$p" || fail 'flags not switched off'
checks+=(opt_out=ok)
printf 'source outcome self-check passed: %s\n' "${checks[*]}"
