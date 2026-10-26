#!/usr/bin/env bash
# Idea 7: doctor replays audit.v2.tsv against canonical frontmatter and the
# current index (read-only); --no-audit-replay / MEMTHENA_DOCTOR_AUDIT_REPLAY=0
# skip it.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-audit-replay.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_DOCTOR_AUDIT_REPLAY MEMTHENA_DOCTOR_AUDIT_REPLAY LLM_BRAIN_DOCTOR_AUDIT_MAX_EVENTS MEMTHENA_DOCTOR_AUDIT_MAX_EVENTS
fail() { printf 'doctor-audit-replay-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_replay"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mk() { # id title body
  printf -- '---\ntype: ReviewItem\ntitle: "%s"\nbrain_project_id: %s\nbrain_candidate_id: %s\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: internal\nbrain_loading_temperature: warm\nbrain_source_authority: user\nbrain_provider_id: fixture\nbrain_provider_version: "1"\nbrain_provenance: "episode://fixture"\nbrain_schema_version: 3\n---\n# %s\n\n%s\n' \
    "$2" "$project_id" "$1" "$2" "$3" >"$project/review/$1.md"
}
promote() { "$cli" --root "$vault" review decide "$project_id" "$1" approved --actor human:test --reason fixture >/dev/null; }
mk claim_keep01 "Ferry timetable" "The harbour ferry leaves every twenty minutes."
mk claim_gone01 "Old ferry pier" "The ferry used the north pier until June."
promote claim_keep01; promote claim_gone01
"$cli" --root "$vault" retract "$project_id" claim_gone01 --reason fixture >/dev/null
"$cli" --root "$vault" index build "$project_id" >/dev/null
doctor() { "$cli" --root "$vault" doctor "$@" 2>"$fixture/err" >"$fixture/out" || true; }

snapshot() { find "$project" -type f -newer "$fixture/stamp" ! -path '*/.locks/*' | sort; }

# Clean vault: no replay mismatch.
doctor
! grep -Fq 'audit replay mismatch' "$fixture/err" || { cat "$fixture/err" >&2; fail 'false positive on clean vault'; }
clean_out="$(cat "$fixture/out")"
# Doctor stdout format is unchanged by the replay on a clean vault.
doctor --no-audit-replay
[ "$(sed 's/[0-9]//g' "$fixture/out")" = "$(printf '%s\n' "$clean_out" | sed 's/[0-9]//g')" ] || fail 'doctor stdout changed'

# Hand-flip a promoted record's lifecycle state behind the audit's back.
sleep 1; : >"$fixture/stamp"
sed -i.bak 's/^brain_review_state: approved$/brain_review_state: proposed/' "$project/okf/claims/claim_keep01.md"; rm -f "$project/okf/claims/claim_keep01.md.bak"
: >"$fixture/stamp"
doctor
grep -Fq "doctor: audit replay mismatch (lifecycle): projects/$project_id/okf/claims/claim_keep01.md" "$fixture/err" || { cat "$fixture/err" >&2; fail 'state flip not reported'; }
grep -q '^memthena: doctor: audit replay mismatch' "$fixture/err" || fail 'message prefix is not memthena:'
# Read-only: doctor wrote nothing into the project.
[ -z "$(snapshot)" ] || { snapshot >&2; fail 'doctor modified the project'; }

# Skip switches.
doctor --no-audit-replay
! grep -Fq 'audit replay' "$fixture/err" || fail '--no-audit-replay did not skip'
MEMTHENA_DOCTOR_AUDIT_REPLAY=0 doctor
! grep -Fq 'audit replay' "$fixture/err" || fail 'MEMTHENA_DOCTOR_AUDIT_REPLAY=0 did not skip'
if MEMTHENA_DOCTOR_AUDIT_REPLAY=maybe "$cli" --root "$vault" doctor >/dev/null 2>&1; then fail 'bad switch value accepted'; fi

# Bounded: an audit longer than the cap is skipped, not half-judged.
MEMTHENA_DOCTOR_AUDIT_MAX_EVENTS=1 doctor
grep -Fq 'audit replay skipped' "$fixture/err" || fail 'max-events cap not honoured'
! grep -Fq 'audit replay mismatch' "$fixture/err" || fail 'truncated replay still judged'

# Restore; then resurrect the retracted record (retraction file removed).
sed -i.bak 's/^brain_review_state: proposed$/brain_review_state: approved/' "$project/okf/claims/claim_keep01.md"; rm -f "$project/okf/claims/claim_keep01.md.bak"
doctor
! grep -Fq 'audit replay mismatch' "$fixture/err" || { cat "$fixture/err" >&2; fail 'restore still mismatched'; }
rm -f "$project/okf/retractions/claim_gone01.md"
sed -i.bak 's/^brain_review_state: superseded$/brain_review_state: approved/' "$project/okf/claims/claim_gone01.md"; rm -f "$project/okf/claims/claim_gone01.md.bak"
doctor
grep -Fq "audit replay mismatch (lifecycle): projects/$project_id/okf/claims/claim_gone01.md" "$fixture/err" || { cat "$fixture/err" >&2; fail 'resurrected retraction not reported'; }

# Helper directly: tab output, summary line.
python3 "$repo_root/lib/memory_signals.py" audit-replay --project-dir "$project" | grep -q $'^summary\tevents=' || fail 'no summary line'
printf 'doctor-audit-replay-self-check: ok\n'
