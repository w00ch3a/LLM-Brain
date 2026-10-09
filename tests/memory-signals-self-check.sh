#!/usr/bin/env bash
# Self-check for the v0.8 memory-signal features: BM25F lexical scoring,
# brain_paths recall, project briefs, intentions, usage/retention signals,
# memory-doctor findings, code anchors, FSRS-style stability, co-use
# association proposals, schema-fit review triage and the diversity guard.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-signals.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'memory signals self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"
workspace="$fixture/workspace"
project_id="proj_memory_signals_self_check"
mkdir -p "$workspace/src/api"
gitc() { GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture git -C "$workspace" "$@"; }
printf 'RETRIES = 7\n' >"$workspace/src/api/client.py"
git -C "$workspace" init -q
gitc add -A
gitc commit -qm initial
anchor_commit="$(git -C "$workspace" rev-parse HEAD)"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
claims="$project_dir/okf/claims"
b() { "$cli" --root "$vault" "$@"; }

claim() {
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}

claim retry-limit 'HTTP retry limit' 'The HTTP client retry limit is 7 attempts.' \
  'brain_paths: ["src/api/**"]' "brain_code_anchors: [\"src/api/client.py@$anchor_commit\"]"
claim deploy-notes 'Deployment notes' "Deployments happen on Tuesdays. $(printf 'Release trains and freeze windows are coordinated weekly. %.0s' $(seq 1 12)) A limit on retry storms is mentioned once."
coffee_text='The coffee machine is on level 2 next to the north stairwell and is descaled every Friday morning by facilities.'
claim coffee 'Coffee machine' "$coffee_text"
claim coffee-copy 'Coffee machine location' "$coffee_text"
claim big-note 'Big runbook' "$(head -c 20000 /dev/zero | tr '\0' 'x' | fold -w 80)"

# 1. BM25F: title-weighted, deterministic; the legacy scorer stays available.
first="$(b search "$project_id" 'retry limit' --limit 5 | sed -n '2p' | cut -f1)"
[ "$first" = okf/claims/retry-limit.md ] || fail "bm25f ranked $first first"
again="$(b search "$project_id" 'retry limit' --limit 5 | cut -f1,2)"
[ "$again" = "$(b search "$project_id" 'retry limit' --limit 5 | cut -f1,2)" ] || fail 'bm25f is not deterministic'
b search "$project_id" 'retry limit' --metadata-file "$fixture/search.meta" >/dev/null
grep -Fxq 'lexical_scorer=bm25f' "$fixture/search.meta" || fail 'bm25f metadata missing'
grep -Fq okf/claims/retry-limit.md <<<"$(LLM_BRAIN_LEXICAL_SCORER=legacy b search "$project_id" 'retry limit' --metadata-file "$fixture/legacy.meta")" || fail 'legacy scorer lost the record'
grep -Fxq 'lexical_scorer=legacy' "$fixture/legacy.meta" || fail 'legacy metadata missing'

# 3. brain_paths: a task naming a matching file recalls the concept even when
#    the words do not match; explicit --path does the same.
grep -Fq okf/claims/retry-limit.md <<<"$(b search "$project_id" 'fix the flaky upload in src/api/client.py')" || fail 'path in query did not recall brain_paths concept'
grep -Fq okf/claims/retry-limit.md <<<"$(b search "$project_id" 'flaky upload' --path src/api/client.py --metadata-file "$fixture/path.meta" | sed -n '2p')" || fail '--path did not recall brain_paths concept'
grep -Fxq 'path_matched_count=1' "$fixture/path.meta" || fail 'path match metadata missing'
mkdir -p "$fixture/bad/claims"
printf '%s\n' '---' 'type: Claim' 'title: Bad' 'brain_paths: ["../escape/**"]' 'brain_code_anchors: ["src/a.py"]' '---' '# Bad' >"$fixture/bad/claims/bad.md"
bad_output="$(python3 "$repo_root/lib/okf.py" validate-bundle "$fixture/bad" 2>&1 || true)"
grep -Fq 'brain_paths' <<<"$bad_output" || fail 'invalid brain_paths accepted'
grep -Fq 'brain_code_anchors' <<<"$bad_output" || fail 'invalid brain_code_anchors accepted'

# 2. Brief: size-capped, read-only and injected by the SessionStart hook.
brief="$(b brief "$project_id" --max-bytes 600)"
[ "$(printf '%s\n' "$brief" | wc -c | tr -d ' ')" -le 600 ] || fail 'brief exceeded its byte cap'
grep -Fq 'LLM-BRAIN PROJECT BRIEF' <<<"$brief" || fail 'brief header missing'
grep -Fq 'HTTP retry limit' <<<"$(b brief "$project_id")" || fail 'brief lacks durable facts'
grep -Fq "$project_id" <<<"$(b brief --source-root "$workspace")" || fail 'brief did not resolve the source root'
[ -z "$(b brief --source-root "$fixture/bad")" ] || fail 'brief invented a project'
[ ! -d "$vault/projects/proj_bad" ] || fail 'brief created a project'
hook_output="$(cd "$workspace" && LLM_BRAIN_ROOT="$vault" sh "$repo_root/hooks/session-start.sh")"
grep -Fq 'Do not require the user to name LLM-Brain.' <<<"$hook_output" || fail 'hook lost its contract'
grep -Fq 'LLM-BRAIN PROJECT BRIEF' <<<"$hook_output" || fail 'hook did not inject the brief'
hook_output="$(cd "$workspace" && LLM_BRAIN_SESSION_BRIEF=0 LLM_BRAIN_ROOT="$vault" sh "$repo_root/hooks/session-start.sh")"
! grep -Fq 'PROJECT BRIEF' <<<"$hook_output" || fail 'LLM_BRAIN_SESSION_BRIEF=0 was ignored'

# 8. Intentions: deterministic triggers, due ones first in packs.
date_id="$(b intention add "$project_id" --action 'Confirm the release freeze' --trigger date:2026-01-02 | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
path_id="$(b intention add "$project_id" --action 'Rerun API contract tests' --trigger 'path:src/api/**' | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
b intention add "$project_id" --action 'Mention the migration' --trigger keyword:migration >/dev/null
state_id="$(b intention add "$project_id" --action 'Re-plan capacity' --trigger state:capacity.workers | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
b intention add "$project_id" --action 'Rotate the key' --trigger 'path:/etc/passwd' >/dev/null 2>&1 && fail 'absolute path trigger accepted'
# Built at runtime so this file itself stays clean under the secret scanner.
fake_secret="tok""en = $(printf 'q%.0s' $(seq 1 24))"
b intention add "$project_id" --action "$fake_secret" --trigger keyword:x >/dev/null 2>&1 && fail 'secret intention accepted'
due="$(b intention list "$project_id" --due | tail -n +2 | cut -f1)"
[ "$due" = "$date_id" ] || fail "unexpected due set: $due"
grep -Fq "$path_id" <<<"$(b intention list "$project_id" --due --path src/api/client.py)" || fail 'path trigger did not fire'
grep -Fq 'Mention the migration' <<<"$(b intention list "$project_id" --due --task 'plan the database migration')" || fail 'keyword trigger did not fire'
claim capacity 'Worker capacity' 'There are 4 workers.' 'brain_state_key: capacity.workers'
grep -Fq "$state_id" <<<"$(b intention list "$project_id" --due)" || fail 'state trigger did not fire after state change'
pack="$(b pack build "$project_id" --task 'retry limit' --path src/api/client.py --receipt | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_intentions_due: 3' "$pack" || fail 'pack intention count missing'
grep -Fq 'Due Intentions' <<<"$(awk '/^## /{print; exit}' "$pack")" || fail 'due intentions are not first'
b intention done "$project_id" "$date_id" --reason 'freeze confirmed' >/dev/null
b intention done "$project_id" "$date_id" --reason 'again' >/dev/null 2>&1 && fail 'closed intention closed twice'
! grep -Fq "$date_id" <<<"$(b intention list "$project_id" --due)" || fail 'done intention still due'
grep -Fq 'intention-done' "$project_dir/audit.v2.tsv" || fail 'intention close was not audited'

# 4 & 11. Usage from receipts/feedback; co-use proposals go through review.
pack_ref="${pack#"$project_dir/"}"
b feedback record "$project_id" --pack "$pack_ref" --usefulness useful >/dev/null
pack_two="$(b pack build "$project_id" --task 'retry limit for deployment notes' --receipt | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
b feedback record "$project_id" --pack "${pack_two#"$project_dir/"}" --usefulness useful >/dev/null
usage="$(b usage "$project_id")"
awk -F '\t' '$1 == "okf/claims/retry-limit.md" && $2 >= 2 && $4 >= 2 { found=1 } END { exit !found }' <<<"$usage" || fail "usage counts missing: $usage"
awk -F '\t' '$1 == "okf/claims/coffee.md" && $2 == 0 && $7 == "never" { found=1 } END { exit !found }' <<<"$usage" || fail 'unused record not reported'
proposal="$(b association propose "$project_id" --min-count 2 --write-review)"
review_id="$(awk -F '\t' 'NR == 2 { print $4 }' <<<"$proposal")"
[ -n "$review_id" ] && [ -f "$project_dir/review/$review_id.md" ] || fail "co-use proposal missing: $proposal"
[ -z "$(find "$project_dir/projections" -name 'association_*.md' 2>/dev/null)" ] || fail 'association built before review'
grep -Fq 'action=derived-association' <<<"$(b review decide "$project_id" "$review_id" approved --reason 'co-use confirmed')" || fail 'approval did not build association'
[ -n "$(find "$project_dir/projections" -name 'association_*.md')" ] || fail 'association projection missing'

# 5, 7 & 4. Maintenance: advisory doctor/retention never changes health; code
#           drift from path@commit anchors is a real finding.
before="$(find "$claims" -type f | LC_ALL=C sort | xargs shasum -a 256)"
report="$(b maintenance preview "$project_id")"
printf '%s\n' "$report" >"$fixture/report.txt"
grep -Fq 'code_drift=0' <<<"$report" || fail 'unexpected code drift'
grep -Eq '^advisory=okf/claims/coffee(-copy)?\.md category=memory-doctor state=likely-duplicate' <<<"$report" || fail 'duplicate not reported'
grep -Eq '^advisory=okf/claims/big-note\.md category=memory-doctor state=oversized' <<<"$report" || fail 'oversized not reported'
grep -Eq '^advisory=okf/claims/coffee\.md category=retention-signal' <<<"$report" || fail 'retention signal missing'
[ "$before" = "$(find "$claims" -type f | LC_ALL=C sort | xargs shasum -a 256)" ] || fail 'maintenance changed canonical memory'
printf 'RETRIES = 3\n' >"$workspace/src/api/client.py"
gitc commit -qam change
report="$(b maintenance preview "$project_id")"
grep -Fq 'code_drift=1' <<<"$report" || fail 'code drift not detected'
grep -Fq 'finding=okf/claims/retry-limit.md category=code-drift' <<<"$report" || fail 'code drift finding missing'
b maintenance preview "$project_id" --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["counts"]["code_drift"] == 1; assert p["advisory_counts"]["memory_doctor"] >= 2'

# 10. Stability: derived suggestion; applying it is explicit and audited.
stability="$(b stability show "$project_id" okf/claims/retry-limit.md)"
awk -F '\t' 'NR == 2 && $1 == "okf/claims/retry-limit.md" && $2 > 0 { found=1 } END { exit !found }' <<<"$stability" || fail "stability row missing: $stability"
suggested="$(awk -F '\t' 'NR == 2 { print $7 }' <<<"$stability")"
grep -Fq "stale_after=$suggested" <<<"$(b stability apply "$project_id" retry-limit --reason 'spaced reverify')" || fail 'stability apply failed'
grep -Fq "stale_after: $suggested" "$claims/retry-limit.md" || fail 'stale_after not updated'
grep -Fq 'stability-apply' "$project_dir/audit.v2.tsv" || fail 'stability apply not audited'
printf '%s\n' '---' 'type: ReviewItem' 'title: Retry limit contradicted' "brain_project_id: $project_id" 'brain_candidate_id: conflict_fixture' 'brain_review_kind: conflict' 'brain_review_state: proposed' 'brain_risk: high' "brain_created_at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"" 'brain_conflicts: ["okf/claims/retry-limit.md"]' '---' '# Conflict' >"$project_dir/review/conflict_fixture.md"
after="$(b stability show "$project_id" okf/claims/retry-limit.md | awk -F '\t' 'NR == 2 { print $2 }')"
python3 -c "import sys; assert float('$after') < float('$(awk -F '\t' 'NR == 2 { print $2 }' <<<"$stability")'), ('$after',)" || fail 'contradiction did not shorten stability'

# 12. Schema-fit triage: conflicts first, fits batched last, nothing promoted.
printf '%s\n' '---' 'type: ReviewItem' 'title: Coffee machine' "brain_project_id: $project_id" 'brain_candidate_id: fit_fixture' 'brain_review_kind: candidate' 'brain_review_state: proposed' 'brain_risk: low' '---' '# Fit' >"$project_dir/review/fit_fixture.md"
printf '%s\n' '---' 'type: ReviewItem' 'title: Brand new idea' "brain_project_id: $project_id" 'brain_candidate_id: novel_fixture' 'brain_review_kind: candidate' 'brain_review_state: proposed' 'brain_risk: low' '---' '# Novel' >"$project_dir/review/novel_fixture.md"
triage="$(b review triage "$project_id")"
[ "$(awk -F '\t' 'NR == 2 { print $1 }' <<<"$triage")" = conflict_fixture ] || fail "conflict not first: $triage"
[ "$(awk -F '\t' 'END { print $1 "/" $5 }' <<<"$triage")" = fit_fixture/low-risk-batch ] || fail "fit not batched last: $triage"
grep -Fq novel_fixture <<<"$(b review list "$project_id" --triage)" || fail 'review list --triage missing rows'
grep -Fq 'brain_review_state: proposed' "$project_dir/review/fit_fixture.md" || fail 'triage changed review state'

# 14. Diversity guard: usage boost keeps a slot for relevant, rarely used records.
for n in 1 2 3 4 5; do claim "ops-$n" "Ops rule $n" "Ops rule $n covers the release checklist."; done
for round in 1 2 3; do
  p="$(b pack build "$project_id" --task 'ops rule release checklist' --budget-tokens 4000 --receipt | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
  b feedback record "$project_id" --pack "${p#"$project_dir/"}" --usefulness useful --notes "round $round" >/dev/null
done
for n in 6 7; do claim "ops-$n" "Ops note $n" "Ops note $n mentions the checklist."; done
b search "$project_id" 'ops rule release checklist' --limit 3 --usage-boost --metadata-file "$fixture/boost.meta" >"$fixture/boost.tsv"
grep -Fxq 'diversity_reserved=2' "$fixture/boost.meta" || fail 'diversity guard did not reserve slots'
grep -Fq okf/claims/ops-6.md "$fixture/boost.tsv" || fail 'rarely used relevant record was starved'
b search "$project_id" 'ops rule release checklist' --limit 3 >"$fixture/noboost.tsv"
! grep -Fq okf/claims/ops-6.md "$fixture/noboost.tsv" || fail 'fixture does not exercise the guard'
grep -Fxq 'usage_boost=enabled' "$fixture/boost.meta" || fail 'usage boost metadata missing'
[ "$(tail -n +2 "$fixture/boost.tsv" | wc -l | tr -d ' ')" = 3 ] || fail 'usage boost changed the limit'
LLM_BRAIN_DIVERSITY_RESERVE=0 b search "$project_id" 'ops rule release checklist' --limit 3 --usage-boost --metadata-file "$fixture/noguard.meta" >/dev/null
grep -Fxq 'diversity_reserved=0' "$fixture/noguard.meta" || fail 'diversity guard did not honour reserve=0'
b search "$project_id" 'ops rule release checklist' --limit 3 --metadata-file "$fixture/plain.meta" >/dev/null
grep -Fxq 'usage_boost=disabled' "$fixture/plain.meta" || fail 'usage boost is not opt-in'

printf '%s\n' 'llm-brain memory signals self-check passed'
