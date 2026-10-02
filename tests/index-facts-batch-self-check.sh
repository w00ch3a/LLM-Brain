#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-index-facts-batch.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'index facts batch self-check: %s\n' "$*" >&2; exit 1; }
tree_hash() {
  python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted((p for p in root.rglob("*") if p.is_file()), key=lambda p: p.relative_to(root).as_posix()):
    digest.update(path.relative_to(root).as_posix().encode("utf-8") + b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

workspace="$fixture/workspace"
vault="$fixture/vault"
project_id=proj_facts_batch_test
mkdir -p "$workspace"
git -C "$workspace" init -q
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
claim="$project/okf/claims/claim.md"
mkdir -p "$(dirname "$claim")"
cat >"$claim" <<'CLAIM'
---
type: Claim
title: Synthetic mutation fixture
status: stable
brain_project_id: proj_facts_batch_test
brain_claim_id: mutation
brain_review_state: approved
brain_sensitivity: internal
brain_source_authority: repository
brain_schema_version: 3
topic_id: synthetic-topic
provenance: synthetic-source
---
# Synthetic mutation fixture

This bounded fixture checks source-byte binding during index facts batching.
CLAIM

"$cli" --root "$vault" index build "$project_id" >/dev/null
previous_generation="$(cat "$project/indexes/current")"
previous_generation_path="$project/indexes/generations/$previous_generation"
previous_generation_hash="$(tree_hash "$previous_generation_path")"
cp "$claim" "$fixture/claim-original.md"
sed 's/brain_sensitivity: internal/brain_sensitivity: restricted/' "$claim" >"$fixture/claim-restricted.md"
sed 's/status: stable/status: deprecated/' "$claim" >"$fixture/claim-deprecated.md"
awk '/brain_sensitivity: internal/ { print; print "brain_sensitivity: restricted"; next } { print }' \
  "$claim" >"$fixture/claim-malformed.md"

real_python="$(command -v python3)"
wrapper="$fixture/python-fault-injector"
cat >"$wrapper" <<'WRAPPER'
#!/bin/bash
facts_helper="$1"
shift
if [ "${1:-}" != facts-batch ]; then
  exec "$FACTS_REAL_PYTHON" "$facts_helper" "$@"
fi
case "$FACTS_TEST_ACTION" in
  before-restricted) cp "$FACTS_TEST_RESTRICTED_FILE" "$FACTS_TEST_FILE" ;;
esac
facts_capture_path="${TMPDIR:-/tmp}/llm-brain-facts-batch-capture.$$"
"$FACTS_REAL_PYTHON" "$facts_helper" "$@" >"$facts_capture_path"
facts_helper_status=$?
if [ "$facts_helper_status" -eq 0 ]; then
  case "$FACTS_TEST_ACTION" in
    after-mutation) printf '\nMutation after facts preparation.\n' >>"$FACTS_TEST_FILE" ;;
    after-delete) rm -f "$FACTS_TEST_FILE" ;;
  esac
fi
cat "$facts_capture_path"
rm -f "$facts_capture_path"
exit "$facts_helper_status"
WRAPPER
chmod +x "$wrapper"

expect_rejected_without_publish() {
  local action="$1"
  if FACTS_REAL_PYTHON="$real_python" FACTS_TEST_ACTION="$action" FACTS_TEST_FILE="$claim" FACTS_TEST_RESTRICTED_FILE="$fixture/claim-restricted.md" \
    LLM_BRAIN_OKF_PYTHON="$wrapper" "$cli" --root "$vault" index build "$project_id" >"$fixture/$action.out" 2>&1; then
    fail "$action source unexpectedly indexed"
  else
    local status=$?
    [ "$status" = 69 ] || fail "$action returned exit $status instead of 69"
  fi
  [ "$(cat "$project/indexes/current")" = "$previous_generation" ] || fail "$action replaced the current generation"
  [ "$(tree_hash "$previous_generation_path")" = "$previous_generation_hash" ] || fail "$action changed the previous generation"
  [ -z "$(find "$project/indexes" -maxdepth 1 -name '.build.*' -print -quit)" ] || fail "$action left an incomplete staging directory"
  [ ! -d "$vault/.locks/project-$project_id.lock" ] || fail "$action left the project lock held"
  grep -Eq 'source-admission-changed|source-changed-during-index|generation-validation-failed' "$project/indexes/rebuild-state.json" || fail "$action did not record source change failure"
}

expect_rejected_without_publish before-restricted
cp "$fixture/claim-original.md" "$claim"
expect_rejected_without_publish after-mutation
cp "$fixture/claim-original.md" "$claim"
expect_rejected_without_publish after-delete
cp "$fixture/claim-original.md" "$claim"

mkdir -p "$fixture/mkdir-wrapper"
real_mkdir="$(command -v mkdir)"
cat >"$fixture/mkdir-wrapper/mkdir" <<'MKDIR_WRAPPER'
#!/bin/bash
"$FACTS_REAL_MKDIR" "$@"
mkdir_status=$?
if [ "$mkdir_status" -ne 0 ] || [ "${1:-}" != "$FACTS_TEST_LOCK_DIR" ] || [ -e "$FACTS_TEST_SENTINEL" ]; then
  exit "$mkdir_status"
fi
: >"$FACTS_TEST_SENTINEL"
case "$FACTS_TEST_ACTION" in
  restricted|deprecated|malformed)
    cp "$FACTS_TEST_VARIANT" "$FACTS_TEST_FILE"
    ;;
  retracted)
    "$FACTS_REAL_MKDIR" -p "$FACTS_TEST_PROJECT/okf/retractions"
    printf '%s\n' '---' 'type: Retraction' 'status: stable' '---' '# Synthetic retraction' >"$FACTS_TEST_PROJECT/okf/retractions/claim.md"
    ;;
  delete) rm -f "$FACTS_TEST_FILE" ;;
  mutate) printf '\nMutation while project lock is held.\n' >>"$FACTS_TEST_FILE" ;;
esac
exit 0
MKDIR_WRAPPER
chmod +x "$fixture/mkdir-wrapper/mkdir"

expect_rejected_under_lock() {
  local action="$1" variant="${2:-}"
  cp "$fixture/claim-original.md" "$claim"
  rm -f "$project/okf/retractions/claim.md" "$fixture/$action.sentinel"
  if FACTS_REAL_PYTHON="$real_python" FACTS_REAL_MKDIR="$real_mkdir" FACTS_TEST_ACTION="$action" \
    FACTS_TEST_FILE="$claim" FACTS_TEST_VARIANT="$variant" FACTS_TEST_PROJECT="$project" \
    FACTS_TEST_LOCK_DIR="$vault/.locks/project-$project_id.lock" FACTS_TEST_SENTINEL="$fixture/$action.sentinel" \
    PATH="$fixture/mkdir-wrapper:$PATH" "$cli" --root "$vault" index build "$project_id" >"$fixture/lock-$action.out" 2>&1; then
    fail "$action replacement under lock unexpectedly indexed"
  else
    local status=$?
    [ "$status" = 69 ] || fail "$action under lock returned exit $status instead of 69"
  fi
  [ -f "$fixture/$action.sentinel" ] || fail "$action fault injection did not run under lock"
  [ "$(cat "$project/indexes/current")" = "$previous_generation" ] || fail "$action under lock replaced current generation"
  [ "$(tree_hash "$previous_generation_path")" = "$previous_generation_hash" ] || fail "$action under lock changed the previous generation"
  [ ! -d "$vault/.locks/project-$project_id.lock" ] || fail "$action under lock left the project lock held"
  [ -z "$(find "$project/indexes" -maxdepth 1 -name '.build.*' -print -quit)" ] || fail "$action under lock left an incomplete stage"
  grep -Eq 'source-admission-changed|source-changed-during-index|generation-validation-failed' "$project/indexes/rebuild-state.json" || fail "$action under lock did not record validation failure"
}

expect_rejected_under_lock restricted "$fixture/claim-restricted.md"
expect_rejected_under_lock deprecated "$fixture/claim-deprecated.md"
expect_rejected_under_lock retracted
expect_rejected_under_lock delete
expect_rejected_under_lock malformed "$fixture/claim-malformed.md"
expect_rejected_under_lock mutate

printf 'llm-brain index facts batch self-check passed\n'
