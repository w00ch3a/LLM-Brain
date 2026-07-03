#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p \
  "$fixture/registry" \
  "$fixture/projects/proj_demo/okf" \
  "$fixture/projects/proj_demo/episodes" \
  "$fixture/projects/proj_demo/concepts" \
  "$fixture/projects/proj_demo/claims" \
  "$fixture/projects/proj_demo/review"

external_root="$fixture/external-source-root"
mkdir -p "$external_root/wiki/concepts"
cat >"$fixture/registry/projects.tsv" <<REGISTRY
schema_version	project_id	alias	fingerprint	git_root	remote	status	updated_at
1	proj_demo	demo	path:$external_root	$external_root		active	2026-07-01T00:00:00Z
REGISTRY

: >"$fixture/projects/proj_demo/audit.log"
cat >"$fixture/projects/proj_demo/okf/index.md" <<'INDEX'
# Demo

See [[External Concept]].
INDEX
cat >"$external_root/wiki/concepts/External Concept.md" <<'EXTERNAL'
# External Concept
EXTERNAL
: >"$fixture/projects/proj_demo/episodes/episode_1.md"
: >"$fixture/projects/proj_demo/concepts/concept_1.md"
: >"$fixture/projects/proj_demo/claims/claim_1.md"
: >"$fixture/projects/proj_demo/review/review_1.md"

doctor_output="$("$repo_root/bin/llm-brain" doctor "$fixture")"
stats_output="$("$repo_root/bin/llm-brain" stats "$fixture")"

case "$doctor_output" in
  *"doctor=ok"*) ;;
  *) printf 'doctor failed: %s\n' "$doctor_output" >&2; exit 1 ;;
esac

case "$stats_output" in
  *"projects=1"*"episodes=1"*"concepts=1"*"claims=1"*"review_items=1"*) ;;
  *) printf 'stats failed: %s\n' "$stats_output" >&2; exit 1 ;;
esac

source_file="$fixture/input-source.md"
cat >"$source_file" <<'SOURCE'
# Source

This is a synthetic source for the self-check.
SOURCE

ingest_output="$("$repo_root/bin/llm-brain" ingest-source proj_demo "$source_file" "$fixture")"
case "$ingest_output" in
  *"ingest-source=ok"*"project=proj_demo"*"source_hash="*"episode="*"review="*) ;;
  *) printf 'ingest failed: %s\n' "$ingest_output" >&2; exit 1 ;;
esac

map_output="$("$repo_root/bin/llm-brain" map proj_demo "$fixture")"
case "$map_output" in
  *"map=ok"*"project=proj_demo"*"INDEX.md"*) ;;
  *) printf 'map failed: %s\n' "$map_output" >&2; exit 1 ;;
esac

case "$(cat "$fixture/projects/proj_demo/INDEX.md")" in
  *"llm-brain:generated-map"*"## Folder Map"*"## Canonical Files"*"## Where To Go"*"okf/index.md"*) ;;
  *) printf 'map file missing expected sections\n' >&2; exit 1 ;;
esac

if grep -Fq "$external_root" "$fixture/projects/proj_demo/INDEX.md"; then
  printf 'map leaked registered source root path\n' >&2
  exit 1
fi

map_second_output="$("$repo_root/bin/llm-brain" map proj_demo "$fixture")"
case "$map_second_output" in
  *"map=ok"*"project=proj_demo"*"INDEX.md"*) ;;
  *) printf 'second generated map failed: %s\n' "$map_second_output" >&2; exit 1 ;;
esac

if "$repo_root/bin/llm-brain" map ../escape "$fixture" >"$fixture/invalid-project.out" 2>&1; then
  printf 'invalid project id unexpectedly passed\n' >&2
  exit 1
fi

case "$(cat "$fixture/invalid-project.out")" in
  *"invalid-project-id"*) ;;
  *) printf 'invalid project id did not report validation failure\n' >&2; exit 1 ;;
esac

mkdir -p "$fixture/projects/proj_human/okf"
: >"$fixture/projects/proj_human/audit.log"
cat >"$fixture/projects/proj_human/okf/index.md" <<'HUMAN_OKF'
# Human OKF Index
HUMAN_OKF
cat >"$fixture/projects/proj_human/INDEX.md" <<'HUMAN_INDEX'
# Human Index
HUMAN_INDEX

if "$repo_root/bin/llm-brain" map proj_human "$fixture" >"$fixture/human-index.out" 2>&1; then
  printf 'human INDEX overwrite unexpectedly passed\n' >&2
  exit 1
fi

case "$(cat "$fixture/human-index.out")" in
  *"map=refuse-existing-index"*) ;;
  *) printf 'human INDEX refusal did not report expected error\n' >&2; exit 1 ;;
esac

case "$(cat "$fixture/projects/proj_human/INDEX.md")" in
  "# Human Index") ;;
  *) printf 'human INDEX was changed\n' >&2; exit 1 ;;
esac

lint_output="$("$repo_root/bin/llm-brain" lint "$fixture")"
case "$lint_output" in
  *"errors=0"*"warnings=0"*) ;;
  *) printf 'lint failed: %s\n' "$lint_output" >&2; exit 1 ;;
esac

secret_file="$fixture/secret-source.md"
cat >"$secret_file" <<'SECRET'
token="sk-123456789012345678901234"
SECRET

if "$repo_root/bin/llm-brain" ingest-source proj_demo "$secret_file" "$fixture" >"$fixture/secret.out" 2>&1; then
  printf 'secret scan unexpectedly passed\n' >&2
  exit 1
fi

case "$(cat "$fixture/secret.out")" in
  *"secret-scan-blocked"*) ;;
  *) printf 'secret scan did not report block\n' >&2; exit 1 ;;
esac

printf 'llm-brain self-check passed\n'
