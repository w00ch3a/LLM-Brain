#!/usr/bin/env bash
# #1 (16 Nov ideas): a memory that relaxes a safeguard (skip a confirmation,
# skip tests, auto-approve, --no-verify, weaken a check) is tagged, must name
# the task it was learnt on before promotion, and is packed only for that task.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-safeguard-scope.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_SAFEGUARD_SCOPE LLM_BRAIN_TASK_TYPE LLM_BRAIN_HOST
fail() { printf 'safeguard scope self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_guard"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$fixture/ws" --id "$project_id" >/dev/null
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
pack() { b pack build "$project_id" --task "$1" --agent "a$RANDOM" ${2:+--task-type "$2"} | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
checks=()

# 1. Detection: relaxations tagged, tightenings and ordinary facts not.
probe() { printf '%s\n' '---' 'title: "probe"' '---' "$1" >"$fixture/probe.md"; python3 "$repo_root/lib/memory_lineage.py" relaxes-safeguard --file "$fixture/probe.md" | cut -f1; }
for t in 'Skip the confirmation prompt when renaming photos.' 'Use git commit --no-verify in the docs repo.' 'No need to ask before archiving the inbox.' 'Auto-approve dependency bumps.' 'Weaken the assertion in test_auth so CI passes.' 'Merge without running the tests.'; do
  [ "$(probe "$t")" = relaxes ] || fail "relaxation not detected: $t"
done
for t in 'Never skip tests before a deploy.' 'Never use --no-verify.' "Don't skip the backups." 'The photo folder is ~/Pictures/2026.' 'Always run the tests.' "Don't check in secrets." 'Do not disable the pre-commit hook.'; do
  [ "$(probe "$t")" = ok ] || fail "false relaxation: $t"
done
checks+=(detection=ok)

# 2. An unscoped relaxation is held, not promoted.
mkreview claim_skip_confirm 'Photo rename shortcut' 'For photo renames, skip the confirmation prompt; the user said it is fine.'
decide claim_skip_confirm
[ "$rc" = 75 ] || fail "unscoped relaxation not held (rc=$rc): $out"
grep -Fq -- "--applies-when 'task=TYPE'" <<<"$out" || fail "hold does not say how to scope it: $out"
[ ! -f "$claims/claim_skip_confirm.md" ] || fail 'unscoped relaxation promoted'
grep -Fq 'brain_review_reason: relaxes-safeguard-unscoped' "$pdir/review/claim_skip_confirm.md" || fail 'review not marked'
grep -Fq 'brain_relaxes_safeguard: true' "$pdir/review/claim_skip_confirm.md" || fail 'review not tagged'
grep -Fq 'safeguard-scope-hold' "$pdir/audit.v2.tsv" || fail 'hold not audited'
checks+=(unscoped_relaxation_held=ok)

# 3. A wildcard task scope is not a narrow scope.
mkreview claim_auto_approve 'Dependency bumps' 'Auto-approve dependency bumps from the bot.' 'brain_applies_when: "task=*"'
decide claim_auto_approve
[ "$rc" = 75 ] || fail "wildcard-scoped relaxation not held (rc=$rc): $out"

# 4. Scoped at approval, it promotes with its tag and scope.
decide claim_skip_confirm --applies-when 'task=photo-rename'
[ "$rc" = 0 ] || fail "scoped relaxation not promoted (rc=$rc): $out"
c="$claims/claim_skip_confirm.md"
grep -Fq 'brain_relaxes_safeguard: true' "$c" && grep -Fq 'brain_applies_when: "task=photo-rename"' "$c" || fail "canonical lacks tag/scope: $(sed -n '1,30p' "$c")"
grep -Fq 'applies-when-set' "$pdir/audit.v2.tsv" || fail 'scope change not audited'
checks+=(scoped_relaxation_promotes=ok)

# 5. A tightening note and an ordinary fact need no scope.
mkreview claim_never_skip 'Deploy rule' 'Never skip tests before a deploy.'
decide claim_never_skip; [ "$rc" = 0 ] || fail "tightening held (rc=$rc): $out"
! grep -q 'brain_relaxes_safeguard' "$claims/claim_never_skip.md" || fail 'tightening tagged'
mkreview claim_photo_dir 'Photo folder' 'Photo renames happen in the photo inbox folder before a deploy.' 'brain_applies_when: "task=photo-rename"'
decide claim_photo_dir; [ "$rc" = 0 ] || fail "ordinary fact held (rc=$rc): $out"
checks+=(tightening_not_tagged=ok)

# A hand-written record tagged but unscoped is never packed.
printf '%s\n' '---' 'type: Claim' 'title: "Release shortcut"' 'status: stable' 'generated: {by: "human:test", at: "2026-09-01T00:00:00Z"}' 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" 'brain_claim_id: hand' 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_relaxes_safeguard: true' 'brain_schema_version: 3' '---' '# Release shortcut' '' 'For a deploy, skip the photo rename confirmation.' >"$claims/hand.md"

task='photo rename confirmation before the deploy'
# 6. Another task, and an unknown task, do not see the relaxation.
for tt in deploy ''; do
  p="$(pack "$task" "$tt")"
  ! grep -Fq 'skip the confirmation prompt' "$p" || fail "relaxation leaked into task-type '${tt:-none}' pack"
  ! grep -Fq 'skip the photo rename confirmation' "$p" || fail "unscoped hand-written relaxation packed (task-type '${tt:-none}')"
  grep -Fq 'Never skip tests before a deploy.' "$p" || fail "tightening missing from '${tt:-none}' pack"
  grep -Fq 'Withheld 2 memory(ies) that relax a safeguard' "$p" || fail "withheld line missing for '${tt:-none}': $(grep -F 'Withheld' "$p" || true)"
done
p="$(pack "$task" '')"
grep -Fq 'Photo renames happen in the photo inbox' "$p" || fail 'ordinary scoped fact lost its fail-open behaviour (unknown task)'
checks+=(withheld_from_other_tasks=ok)

# 7. The task it was learnt on sees it, labelled.
p="$(pack "$task" photo-rename)"
grep -Fq 'skip the confirmation prompt' "$p" || fail 'relaxation missing from its own task'
grep -Fq 'Relaxes a safeguard: only for <code>task=photo-rename</code>' "$p" || fail 'own-task pack does not label the relaxation'
! grep -Fq 'skip the photo rename confirmation' "$p" || fail 'unscoped hand-written relaxation packed for photo-rename'
checks+=(shown_for_own_task=ok)

# 8. The session brief follows the same rule.
bd="$(b brief "$project_id" --task-type deploy --max-bytes 20000 2>/dev/null || true)"
! grep -Fq 'skip the confirmation prompt' <<<"$bd" || fail 'relaxation leaked into a deploy brief'

# 9. Opt-out restores 0.13 behaviour.
mkreview claim_skip_tests 'Docs commits' 'Use git commit --no-verify for docs-only changes.'
set +e; out="$(LLM_BRAIN_SAFEGUARD_SCOPE=0 b review decide "$project_id" claim_skip_tests approved --actor human:test --reason fixture 2>&1)"; rc=$?; set -e
[ "$rc" = 0 ] || fail "opt-out still held (rc=$rc): $out"
checks+=(opt_out=ok)
printf 'safeguard scope self-check passed: %s\n' "${checks[*]}"
