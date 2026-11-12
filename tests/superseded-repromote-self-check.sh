#!/usr/bin/env bash
# #1 (2 Nov ideas): promotion defers a candidate that repeats a version that
# has already been replaced, so a stale capture cannot roll an old fact back.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-repromote.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'superseded re-promotion self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_repromote"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"; claims="$project_dir/okf/claims"
b() { "$cli" --root "$vault" "$@"; }
claim() {
  local id="$1" title="$2" body="$3" at="$4"; shift 4
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
mkreview() { # id title body [extra frontmatter lines]
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: ReviewItem' "title: \"$title\"" "brain_project_id: $project_id" "brain_candidate_id: $id" 'brain_review_kind: claim' 'brain_review_state: proposed' 'brain_confidence: 0.9' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_loading_temperature: warm' 'brain_source_authority: user' 'brain_provider_id: fixture' 'brain_provider_version: "1"' 'brain_provenance: "episode://fixture"'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$project_dir/review/$id.md"
}
decide() { set +e; out="$(b review decide "$project_id" "$1" approved --actor human:test --reason fixture "${@:2}" 2>&1)"; rc=$?; set -e; }
checks=()

claim port-v1 'Staging port' 'The staging deploy listens on port 8080.' 2026-01-01T00:00:00Z
claim port-v2 'Staging port (moved)' 'The staging deploy listens on port 8443.' 2026-03-01T00:00:00Z 'brain_supersedes: ["okf/claims/port-v1.md"]'
claim cache-v1 'Cache size' 'The build cache holds 20 GB.' 2026-01-01T00:00:00Z 'brain_state_key: build.cache'
claim cache-v2 'Cache size' 'The build cache holds 50 GB.' 2026-02-01T00:00:00Z 'brain_state_key: build.cache'

# 1. A stale capture repeating the explicitly superseded version is deferred.
mkreview claim_stale_port 'Staging deploy port' 'The staging deploy listens on port 8080.'
decide claim_stale_port
[ "$rc" = 75 ] || fail "stale repeat not refused (rc=$rc): $out"
grep -Fq 'port-v1.md' <<<"$out" || fail "refusal does not name the old version: $out"
[ ! -f "$claims/claim_stale_port.md" ] || fail 'old version re-promoted'
grep -Fq 'brain_review_reason: superseded-version' "$project_dir/review/claim_stale_port.md" || fail 'review not marked'
grep -Fq 'superseded-repeat-hold' "$project_dir/audit.v2.tsv" || fail 'hold not audited'
checks+=(explicit_superseded_repeat_deferred=ok)

# 2. An older value of a state key is caught the same way.
mkreview claim_stale_cache 'Build cache size' 'The build cache holds 20 GB.' 'brain_state_key: build.cache'
decide claim_stale_cache
[ "$rc" = 75 ] && grep -Fq 'cache-v1.md' <<<"$out" || fail "older state value not deferred (rc=$rc): $out"
checks+=(older_state_value_deferred=ok)

# 3. A genuinely new value is not caught (same words, different number).
mkreview claim_new_port 'Staging port (new)' 'The staging deploy listens on port 9443.'
decide claim_new_port
[ "$rc" = 0 ] && [ -f "$claims/claim_new_port.md" ] || fail "new value wrongly deferred (rc=$rc): $out"
checks+=(new_value_promotes=ok)

# 4. A deliberate rollback that names the replacement is left to the belief check.
mkreview claim_rollback 'Staging port (rolled back)' 'The staging deploy listens on port 8080.' 'brain_supersedes: ["okf/claims/claim_new_port.md"]'
decide claim_rollback --overrule-belief
grep -Fq 'brain_review_reason: superseded-version' "$project_dir/review/claim_rollback.md" && fail "deliberate rollback held as stale repeat: $out"
checks+=(deliberate_rollback_not_flagged=ok)

# 5. Explicit restore promotes and is audited.
decide claim_stale_port --restore-superseded
[ "$rc" = 0 ] && [ -f "$claims/claim_stale_port.md" ] || fail "restore refused (rc=$rc): $out"
grep -Fq 'superseded-restore' "$project_dir/audit.v2.tsv" || fail 'restore not audited'
checks+=(explicit_restore_audited=ok)

printf 'superseded re-promotion self-check passed: %s\n' "${checks[*]}"
