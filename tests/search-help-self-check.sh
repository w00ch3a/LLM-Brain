#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-search-help.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
for option in --help -h help; do
  "$repo_root/bin/llm-brain" search "$option" >"$fixture/out" 2>"$fixture/err"
  grep -Fq 'Usage: llm-brain search PROJECT_ID QUERY' "$fixture/out"
  test ! -s "$fixture/err"
done
for count in 0 1; do
  status=0
  if [ "$count" = 0 ]; then
    "$repo_root/bin/llm-brain" search >"$fixture/out" 2>"$fixture/err" || status=$?
  else
    "$repo_root/bin/llm-brain" search project >"$fixture/out" 2>"$fixture/err" || status=$?
  fi
  test "$status" = 64
  grep -Fq 'search requires PROJECT_ID and QUERY' "$fixture/err"
  if grep -Fq 'unbound variable' "$fixture/err"; then exit 1; fi
done
printf 'search-help self-check passed\n'
