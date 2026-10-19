#!/usr/bin/env bash
# Lexical profile v2 (default) vs legacy: v2 must find stemmed words,
# version strings, short identifiers, camelCase parts and accented words that
# the legacy BM25F misses or ties; LLM_BRAIN_LEXICAL_PROFILE=legacy must keep
# the legacy order; metadata records the profile only when it is not legacy;
# invalid values are refused. No model, no index.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-lexical-profile.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$fixture"' EXIT
fail() { printf 'lexical profile self-check: %s\n' "$*" >&2; exit 1; }

workspace="$fixture/workspace"; vault="$fixture/vault"; project_id=proj_lexical_profile_test
mkdir -p "$workspace"
git -C "$workspace" init -q
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims"

claim() {
  local id="$1" title="$2" body="$3"
  {
    printf -- '---\ntype: Claim\ntitle: "%s"\nstatus: stable\nbrain_project_id: %s\nbrain_claim_id: %s\n' "$title" "$project_id" "$id"
    printf 'brain_review_state: approved\nbrain_sensitivity: internal\nbrain_source_authority: repository\nbrain_schema_version: 3\n'
    printf -- '---\n# %s\n\n%s\n' "$title" "$body"
  } >"$project/okf/claims/$id.md"
}
claim a-api-143 "Gateway api status" "The gateway api is at 1.4.3 as of June. Release is held."
claim b-api-142 "Gateway api status" "The gateway api is at 1.4.2 as of May. Release is held."
claim a-corolla "Corolla service" "The Corolla service is due every 10000 km at the usual garage."
claim b-cx5 "CX-5 service" "The CX-5 service is due every 8000 km at the usual garage."
claim c-retries "Uploader behaviour" "The uploader retries failed chunks three times, then gives up and logs it."
claim d-cafe "Café opening hours" "The café on the corner opens at seven on weekdays."
claim f-backup-db "Backup target" "Nightly backup runs on the DB host."
claim g-backup-pi "Backup target" "Nightly backup runs on the Pi host."
claim e-code "Profile lookup helper" "Call getUserName from the profile module before rendering the header."
for n in 1 2 3 4 5 6; do claim "z-filler-$n" "Garden note $n" "Water the herbs and check the garage door on day $n."; done

top() { # PROFILE QUERY -> first result path
  local profile="$1" query="$2"
  env LLM_BRAIN_LEXICAL_PROFILE="$profile" "$cli" --root "$vault" search "$project_id" "$query" --limit 5 --strategy lexical \
    --metadata-file "$fixture/meta.$profile" | awk -F '\t' 'NR == 2 { print $1; exit }'
}
expect_top() { # PROFILE QUERY EXPECTED
  local got; got="$(top "$1" "$2")"
  [ "$got" = "okf/claims/$3.md" ] || fail "$1 '$2': top is '$got', expected $3"
}

# Version strings and short identifiers: legacy drops 1/4/2 and "cx"/"5".
expect_top v2 "gateway api 1.4.2" b-api-142
expect_top legacy "gateway api 1.4.2" a-api-143
expect_top v2 "CX-5 service" b-cx5
expect_top v2 "nightly backup pi" g-backup-pi
expect_top legacy "nightly backup pi" f-backup-db
# Stemming (retry -> retries), camelCase parts, accent folding.
expect_top v2 "retry chunk" c-retries
expect_top v2 "user name" e-code
expect_top v2 "cafe opening" d-cafe
expect_top v2 "café opening" d-cafe

# Default is v2; metadata names the profile only when it is not legacy.
"$cli" --root "$vault" search "$project_id" "gateway api 1.4.2" --limit 5 --metadata-file "$fixture/meta.default" >"$fixture/default.out"
env LLM_BRAIN_LEXICAL_PROFILE=v2 "$cli" --root "$vault" search "$project_id" "gateway api 1.4.2" --limit 5 --metadata-file "$fixture/meta.v2" >"$fixture/v2.out"
cmp -s "$fixture/default.out" "$fixture/v2.out" || fail "default profile is not v2"
grep -qx 'lexical_profile=v2' "$fixture/meta.default" || fail "metadata misses lexical_profile=v2"
env LLM_BRAIN_LEXICAL_PROFILE=legacy "$cli" --root "$vault" search "$project_id" "gateway api 1.4.2" --limit 5 --metadata-file "$fixture/meta.legacy" >/dev/null
if grep -q '^lexical_profile=' "$fixture/meta.legacy"; then fail "legacy metadata gained a lexical_profile line"; fi

# The helper agrees with the search fast path for both profiles.
find "$project/okf" -name '*.md' ! -name index.md ! -name log.md | LC_ALL=C sort >"$fixture/paths"
for profile in v2 legacy; do
  env LLM_BRAIN_LEXICAL_PROFILE="$profile" python3 "$repo_root/lib/memory_signals.py" bm25 --project-dir "$project" \
    --paths-file "$fixture/paths" --query "gateway api 1.4.2" | cut -f1 | awk 'NF' >"$fixture/helper.$profile"
  env LLM_BRAIN_LEXICAL_PROFILE="$profile" "$cli" --root "$vault" search "$project_id" "gateway api 1.4.2" --limit 50 --strategy lexical |
    awk -F '\t' 'NR > 1 { print $1 }' >"$fixture/search.$profile"
  cmp -s "$fixture/helper.$profile" "$fixture/search.$profile" || fail "$profile: helper and search order differ"
done
cmp -s "$fixture/helper.v2" "$fixture/helper.legacy" && fail "v2 and legacy produced the same order"

# Structural extensions (v2 only; on by default, =0 turns each off).
claim_meta() { # ID TITLE BODY EXTRA-FRONTMATTER
  local id="$1" title="$2" body="$3" extra="$4"
  {
    printf -- '---\ntype: Claim\ntitle: "%s"\nstatus: stable\nbrain_project_id: %s\nbrain_claim_id: %s\n' "$title" "$project_id" "$id"
    printf 'brain_review_state: approved\nbrain_sensitivity: internal\nbrain_source_authority: repository\nbrain_schema_version: 3\n%b\n' "$extra"
    printf -- '---\n# %s\n\n%s\n' "$title" "$body"
  } >"$project/okf/claims/$id.md"
}
claim_meta h-bench "Staging benchmark run" "Measured p95 latency fell from 410 ms to 120 ms on the staging host." ""
claim_meta i-decision "Switch the queue to Kafka" "Decision: move the queue to Kafka. Evidence: [staging benchmark](okf/claims/h-bench.md)." ""
claim_meta j-sched-a "Mirror job schedule" "The mirror job runs at 04:00 every night." 'brain_state_key: mirror/schedule\nbrain_valid_from: "2026-08-01T00:00:00Z"'
claim_meta k-sched-b "Mirror job schedule" "The mirror job runs at 01:00 every night." 'brain_state_key: mirror/schedule\nbrain_valid_from: "2026-02-01T00:00:00Z"'
toplist() { env "$@" "$cli" --root "$vault" search "$project_id" "$QUERY" --limit 3 --strategy lexical | awk -F '\t' 'NR == 2 { print $1; exit }'; }
QUERY="evidence for the queue switch to Kafka"
top3() { env "$@" "$cli" --root "$vault" search "$project_id" "$QUERY" --limit 3 --strategy lexical | awk -F '\t' 'NR > 1 && NR <= 3 { print $1 }'; }
# The linking decision stays first (it is a fair answer); the evidence it links to is pulled in behind it.
top3 LLM_BRAIN_LEXICAL_ANCHORS=1 | grep -qx okf/claims/h-bench.md || fail "anchors: linked evidence not in the top 2"
top3 | grep -qx okf/claims/h-bench.md || fail "anchors default: linked evidence not in the top 2 with the flag unset"
[ "$(top3)" = "$(top3 LLM_BRAIN_LEXICAL_ANCHORS=1)" ] || fail "anchors default differs from =1"
if top3 LLM_BRAIN_LEXICAL_ANCHORS=0 | grep -qx okf/claims/h-bench.md; then fail "anchors off: evidence matched without anchors"; fi
QUERY="mirror job schedule"
[ "$(toplist LLM_BRAIN_LEXICAL_STATE_ORDER=0)" = okf/claims/j-sched-a.md ] || fail "state order off: unexpected tie order"
sed -i.bak 's/2026-08-01/2025-08-01/' "$project/okf/claims/j-sched-a.md"; rm -f "$project/okf/claims/"*.bak
[ "$(toplist LLM_BRAIN_LEXICAL_STATE_ORDER=1)" = okf/claims/k-sched-b.md ] || fail "state order: newest sibling not on top"
[ "$(toplist)" = okf/claims/k-sched-b.md ] || fail "state order default: newest sibling not on top with the flag unset"
[ "$(toplist LLM_BRAIN_LEXICAL_STATE_ORDER=0)" = okf/claims/j-sched-a.md ] || fail "state order =0: still reordered"
sed -i.bak '/^brain_valid_from:/d' "$project/okf/claims/k-sched-b.md"; rm -f "$project/okf/claims/"*.bak
[ "$(toplist LLM_BRAIN_LEXICAL_STATE_ORDER=1)" = "$(toplist LLM_BRAIN_LEXICAL_STATE_ORDER=0)" ] || fail "state order: undated group was reordered"
# Legacy ignores both switches.
QUERY="evidence for the queue switch to Kafka"
[ "$(top3 LLM_BRAIN_LEXICAL_PROFILE=legacy)" = "$(top3 LLM_BRAIN_LEXICAL_PROFILE=legacy LLM_BRAIN_LEXICAL_ANCHORS=0 LLM_BRAIN_LEXICAL_STATE_ORDER=0)" ] ||
  fail "legacy: structural switches changed the order"
for flag in LLM_BRAIN_LEXICAL_ANCHORS LLM_BRAIN_LEXICAL_STATE_ORDER; do
  set +e; env "$flag=yes" "$cli" --root "$vault" search "$project_id" mirror >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = 64 ] || fail "$flag=yes exit $rc, expected 64"
done

# Invalid values are refused before any scoring.
set +e
env LLM_BRAIN_LEXICAL_PROFILE=fancy "$cli" --root "$vault" search "$project_id" "gateway" >/dev/null 2>"$fixture/bad.err"; rc=$?
set -e
[ "$rc" = 64 ] || fail "invalid profile exit $rc, expected 64"
grep -q 'LLM_BRAIN_LEXICAL_PROFILE must be v2 or legacy' "$fixture/bad.err" || fail "invalid profile message missing"

printf 'lexical-profile-self-check=ok\n'
