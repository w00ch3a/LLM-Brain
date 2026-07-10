#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'v2 self-check: %s\n' "$*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_contains() { printf '%s' "$1" | grep -Fq "$2" || fail "expected output to contain: $2"; }

repo="$fixture/repo"
vault="$fixture/vault"
mkdir -p "$repo" "$vault"
git -C "$repo" init -q
git -C "$repo" remote add origin https://example.invalid/brain-demo.git

project_output="$($cli --root "$vault" project ensure "$repo")"
project_id="$(printf '%s\n' "$project_output" | sed -n 's/.*project_id=\([^ ]*\).*/\1/p')"
[ -n "$project_id" ] || fail "project id missing"
assert_contains "$($cli --root "$vault" project ensure "$repo")" 'changed=0'

topic_output="$($cli --root "$vault" topic add "$project_id" "Automatic Memory")"
topic_id="$(printf '%s\n' "$topic_output" | sed -n 's/.*topic_id=\([^ ]*\).*/\1/p')"
[ -n "$topic_id" ] || fail "topic id missing"

source="$fixture/source.md"
cat >"$source" <<'SOURCE'
# Source

This repository uses calm deterministic memory files.
SOURCE

capture="$($cli --root "$vault" ingest-source "$project_id" "$source")"
assert_contains "$capture" 'ingest-source=ok'
episode_ref="$(printf '%s\n' "$capture" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -1)"

candidate="$fixture/candidate.md"
cat >"$candidate" <<EOF
---
type: ReviewItem
title: Durable memory uses inspectable files
brain_review_kind: claim
brain_confidence: 0.95
brain_risk: low
brain_sensitivity: internal
brain_loading_temperature: warm
brain_source_authority: repository
brain_provider_id: fixture-provider
brain_provider_version: 1
brain_provenance: "episode://$(basename "$episode_ref" .md)"
---
# Durable memory uses inspectable files

The project stores durable memory in human-readable files.
EOF

promotion="$($cli --root "$vault" reflect submit "$project_id" "$candidate")"
assert_contains "$promotion" 'promotion=ok'
claim_id="$(printf '%s\n' "$promotion" | sed -n 's/.*canonical=.*\/\([^/]*\)\.md/\1/p')"
[ -n "$claim_id" ] || fail "automatic promotion did not create a claim"

search="$($cli --root "$vault" search "$project_id" 'durable memory')"
assert_contains "$search" "$claim_id"

pack="$($cli --root "$vault" pack build "$project_id" --agent generic --task 'durable memory' --budget-tokens 200)"
pack_file="$(printf '%s\n' "$pack" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
assert_file "$pack_file"
grep -Fq 'The project stores durable memory' "$pack_file" || fail "pack lacks selected memory"
grep -Fq 'Source hash:' "$pack_file" || fail "pack lacks source provenance"

embedder="$fixture/embedder.sh"
cat >"$embedder" <<'EMBEDDER'
#!/usr/bin/env bash
printf 'model: fixture-embedder\ndimensions: 3\nvector: 0.1 0.2 0.3\n'
EMBEDDER
chmod 755 "$embedder"
LLM_BRAIN_EMBEDDER_VERSION=v1 "$cli" --root "$vault" index build "$project_id" --embedder "$embedder" >/dev/null
assert_file "$vault/projects/$project_id/indexes/vectors.tsv"
assert_contains "$(LLM_BRAIN_EMBEDDER_VERSION=v1 "$cli" --root "$vault" index status "$project_id")" 'vector_search=available'
LLM_BRAIN_EMBEDDER_VERSION=v2 "$cli" --root "$vault" index build "$project_id" --embedder "$embedder" >/dev/null
[ "$(find "$vault/projects/$project_id/indexes/embeddings" -type f -name '*.txt' | wc -l | tr -d ' ')" -ge 2 ] || fail "embedding cache did not vary by provider version"

high_risk="$fixture/high-risk.md"
cat >"$high_risk" <<EOF
---
type: ReviewItem
title: Production deployment change
brain_review_kind: procedure
brain_confidence: 0.99
brain_risk: high
brain_sensitivity: internal
brain_loading_temperature: warm
brain_source_authority: repository
brain_provider_id: fixture-provider
brain_provider_version: 1
brain_provenance: "episode://$(basename "$episode_ref" .md)"
---
# Production deployment change

Deploy production infrastructure.
EOF

queued="$($cli --root "$vault" reflect submit "$project_id" "$high_risk")"
assert_contains "$queued" 'review=queued'
review_id="$(printf '%s\n' "$queued" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
review_list="$($cli --root "$vault" review list "$project_id" --state proposed)"
assert_contains "$review_list" "$review_id"

provider="$fixture/provider.sh"
cat >"$provider" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
request="$1"
output="$2"
mkdir -p "$output"
episode_id="$(awk '/^brain_episode_id:/ { print $2; exit }' "$request")"
cat >"$output/provider-candidate.md" <<CANDIDATE
---
type: ReviewItem
title: Provider distilled fact
brain_review_kind: claim
brain_confidence: 0.95
brain_risk: low
brain_sensitivity: internal
brain_loading_temperature: warm
brain_source_authority: repository
brain_provider_id: fixture-provider
brain_provider_version: 1
brain_provenance: "episode://$episode_id"
---
# Provider distilled fact

Provider reflection can be run through an explicit executable.
CANDIDATE
PROVIDER
chmod 755 "$provider"

reflection="$($cli --root "$vault" reflect run "$project_id" --provider "$provider")"
assert_contains "$reflection" 'episodes=1'
assert_contains "$($cli --root "$vault" reflect run "$project_id" --provider "$provider")" 'episodes=0'

slow_provider="$fixture/slow-provider.sh"
cat >"$slow_provider" <<'SLOW'
#!/usr/bin/env bash
sleep 3
SLOW
chmod 755 "$slow_provider"
if LLM_BRAIN_PROVIDER_TIMEOUT_SECONDS=1 "$cli" --root "$vault" reflect run "$project_id" --provider "$slow_provider" --force --limit 1 >"$fixture/timeout.out" 2>&1; then
  fail "timed-out provider unexpectedly succeeded"
fi
assert_contains "$(cat "$fixture/timeout.out")" 'timed out'

$cli --root "$vault" retract "$project_id" "$claim_id" --reason 'fixture retraction' >/dev/null
search_after="$($cli --root "$vault" search "$project_id" 'durable memory')"
if printf '%s\n' "$search_after" | grep -Fq "$claim_id"; then fail "retracted claim remained searchable"; fi

$cli --root "$vault" adapters build "$project_id" --agent generic >/dev/null
assert_file "$vault/projects/$project_id/adapters/generic.md"
catalog="$($cli --root "$vault" export knowledge-catalog "$project_id")"
catalog_path="$(printf '%s\n' "$catalog" | sed -n 's/.*path=\([^ ]*\).*/\1/p')"
assert_file "$catalog_path/manifest.tsv"
bundle="$($cli --root "$vault" export bundle "$project_id")"
bundle_path="$(printf '%s\n' "$bundle" | sed -n 's/.*path=\([^ ]*\).*/\1/p')"
assert_file "$bundle_path"
$cli --root "$vault" --project-id "$project_id" import bundle "$bundle_path" --dry-run >/dev/null 2>/dev/null

duplicate_root_line="$(tail -1 "$vault/registry/roots.tsv")"
printf '%s\n' "$duplicate_root_line" >>"$vault/registry/roots.tsv"

legacy_source="$fixture/legacy-md5.md"
printf '# Legacy MD5 source\n\nExact legacy bytes.\n' >"$legacy_source"
legacy_md5="$(md5 -q "$legacy_source" 2>/dev/null || md5sum "$legacy_source" | awk '{print $1}')"
cat >"$vault/projects/$project_id/episodes/episode_legacy_md5.md" <<EOF
---
type: Episode
brain_project_id: $project_id
brain_episode_id: episode_legacy_md5
brain_source_path: $legacy_source
brain_source_hash: $legacy_md5
brain_review_state: captured
---
# Legacy MD5 episode
EOF

drifted_source="$fixture/drifted-source.md"
printf '# Historical bytes\n' >"$drifted_source"
drifted_sha="$(shasum -a 256 "$drifted_source" | awk '{print $1}')"
printf '# Current, different bytes\n' >"$drifted_source"
cat >"$vault/projects/$project_id/episodes/episode_drifted_source.md" <<EOF
---
type: Episode
brain_project_id: $project_id
brain_episode_id: episode_drifted_source
brain_source_path: $drifted_source
brain_source_hash: $drifted_sha
brain_review_state: captured
---
# Drifted source episode
EOF
cat >"$vault/projects/$project_id/okf/procedures/procedure_revalidate_source.md" <<EOF
---
type: Procedure
brain_project_id: $project_id
brain_procedure_id: procedure_revalidate_source
brain_review_state: approved
brain_sensitivity: internal
source_episode: episode_drifted_source
---
# Procedure requiring current authority

The current authority source validates this procedure.
EOF
scaffold="$vault/projects/$project_id/review/claim_scaffold.md"
cat >"$scaffold" <<'SCAFFOLD'
---
type: ReviewItem
brain_candidate_id: claim_scaffold
brain_review_kind: claim
brain_review_state: proposed
---
# Scaffold

Candidate statement: source context for legacy data.
SCAFFOLD

cat >"$vault/projects/$project_id/okf/claims/claim_scaffold.md" <<'LEGACY_CANONICAL'
---
type: Claim
brain_project_id: fixture
brain_claim_id: claim_scaffold
brain_review_state: approved
brain_sensitivity: internal
---
# Scaffolded claim

Candidate statement: source context for legacy data.
LEGACY_CANONICAL

check="$($cli --root "$vault" migrate check)"
assert_contains "$check" 'duplicate_root_rows=1'
assert_contains "$check" 'retractable_canonical=1'

if ! migration="$($cli --root "$vault" migrate apply --all 2>&1)"; then
  fail "migration failed: $migration"
fi
assert_contains "$migration" 'migration=ok'
assert_contains "$(cat "$vault/projects/$project_id/schema.version")" '2'
[ "$(grep -Fc "$duplicate_root_line" "$vault/registry/roots.tsv")" = "1" ] || fail "migration did not remove exact duplicate root row"
assert_contains "$(cat "$vault/projects/$project_id/review/claim_scaffold.md")" 'brain_review_state: superseded'
assert_file "$vault/projects/$project_id/okf/retractions/claim_scaffold.md"
assert_contains "$(cat "$vault/projects/$project_id/migrations/source-reconciliation.tsv")" 'recovered-legacy-md5'
assert_contains "$($cli --root "$vault" migrate check)" 'source_unresolved=1'
$cli --root "$vault" validate-source "$project_id" procedure_revalidate_source "$source" --reason 'fixture current authority' >/dev/null
if grep -Fq 'source_episode:' "$vault/projects/$project_id/okf/procedures/procedure_revalidate_source.md"; then fail "validate-source retained superseded episode dependency"; fi
assert_contains "$(cat "$vault/projects/$project_id/okf/procedures/procedure_revalidate_source.md")" 'brain_source_hash_sha256:'
reconciled="$($cli --root "$vault" migrate reconcile-sources "$project_id" --finalise-missing --reason 'fixture source bytes unavailable')"
assert_contains "$reconciled" 'finalised=1'
assert_contains "$(cat "$vault/projects/$project_id/episodes/episode_drifted_source.md")" 'brain_source_reconciliation_state: unrecoverable'
assert_contains "$($cli --root "$vault" migrate check)" 'source_unresolved=0'
assert_contains "$($cli --root "$vault" migrate check)" 'source_unrecoverable=1'
assert_contains "$($cli --root "$vault" migrate verify)" 'migration_verify=ok'

printf 'tamper\n' >>"$vault/projects/$project_id/audit.v2.tsv"
if "$cli" --root "$vault" lint >"$fixture/tamper.out" 2>&1; then
  fail "tampered audit unexpectedly passed lint"
fi
assert_contains "$(cat "$fixture/tamper.out")" 'truncated audit event'

printf 'llm-brain v2 self-check passed\n'
