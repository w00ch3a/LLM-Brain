#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output="$(LLM_BRAIN_RELEASE_RUNNER_SELF_TEST=1 bash "$repo_root/tests/release-readiness-self-check.sh")"
printf '%s\n' "$output" | grep -Fqx 'release-runner-self-test=passed'
