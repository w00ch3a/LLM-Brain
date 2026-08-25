#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="${1:-default}"
case "$mode" in
  default) release_mode=0 ;;
  --release) release_mode=1 ;;
  *)
    printf 'usage: %s [--release]\n' "${BASH_SOURCE[0]}" >&2
    exit 64
    ;;
esac

fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-release-readiness.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
logs="$fixture/logs"
mkdir -p "$logs"
failures=0

run_group() {
  local name="$1"
  shift
  local log="$logs/$name.log"
  if "$@" >"$log" 2>&1; then
    printf 'PASS %-16s\n' "$name"
  else
    failures=$((failures + 1))
    printf 'FAIL %-16s\n' "$name"
    sed -n '1,240p' "$log" >&2
  fi
}

static_checks() {
  bash -n "$repo_root/bin/llm-brain"
  python3 -m py_compile "$repo_root/lib/okf.py"
  find "$repo_root/tests" -type f -name '*self-check.sh' -print0 |
    while IFS= read -r -d '' test_file; do bash -n "$test_file"; done
  git -C "$repo_root" diff --check
}

core_checks() {
  bash "$repo_root/tests/self-check.sh"
  bash "$repo_root/tests/okf-self-check.sh"
  bash "$repo_root/tests/v3-self-check.sh"
  bash "$repo_root/tests/reflection-scheduler-self-check.sh"
  bash "$repo_root/tests/work-self-check.sh"
  bash "$repo_root/tests/state-commitment-capsule-self-check.sh"
  bash "$repo_root/tests/temporal-self-check.sh"
  bash "$repo_root/tests/retrieval-planner-self-check.sh"
  bash "$repo_root/tests/procedure-run-self-check.sh"
  bash "$repo_root/tests/reconsolidation-self-check.sh"
  bash "$repo_root/tests/scope-feedback-self-check.sh"
  bash "$repo_root/tests/experimental-gates-self-check.sh"
  bash "$repo_root/tests/eval-self-check.sh"
}

compatibility_checks() {
  bash "$repo_root/tests/compatibility-self-check.sh"
  bash "$repo_root/tests/hermes-integration-self-check.sh"
}

upgrade_checks() {
  bash "$repo_root/tests/upgrade-self-check.sh"
}

packaging_checks() {
  bash "$repo_root/scripts/package-ai-skill.sh"
  bash "$repo_root/tests/automatic-use-self-check.sh"
}

presentation_checks() {
  bash "$repo_root/tests/presentation-self-check.sh"
}

release_checks() {
  local skills_root hermes_root package_dir version
  version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
  if [ -n "${CODEX_SKILLS_ROOT:-}" ]; then
    skills_root="$CODEX_SKILLS_ROOT"
  elif [ -n "${CODEX_HOME:-}" ]; then
    skills_root="$CODEX_HOME/skills"
  else
    skills_root="$HOME/.codex/skills"
  fi
  hermes_root="${HERMES_SOURCE_ROOT:-$HOME/.hermes/hermes-agent}"
  package_dir="$fixture/hermes-package"
  [ -d "$hermes_root" ] || {
    printf 'required Hermes source is unavailable: %s\n' "$hermes_root" >&2
    return 1
  }
  [ -f "$skills_root/.system/skill-creator/scripts/quick_validate.py" ] ||
    { printf 'skill validator is unavailable under %s\n' "$skills_root" >&2; return 1; }
  [ -f "$skills_root/.system/plugin-creator/scripts/validate_plugin.py" ] ||
    { printf 'plugin validator is unavailable under %s\n' "$skills_root" >&2; return 1; }
  HERMES_SOURCE_ROOT="$hermes_root" bash "$repo_root/tests/hermes-integration-self-check.sh"
  bash "$repo_root/scripts/package-hermes-plugin.sh" "$package_dir"
  grep -Fqx "version: $version" "$package_dir/plugin.yaml"
  [ -f "$package_dir/README.md" ]
  python3 "$skills_root/.system/skill-creator/scripts/quick_validate.py" "$repo_root/skills/llm-brain"
  python3 "$skills_root/.system/skill-creator/scripts/quick_validate.py" "$repo_root/skills/llm-brain-upgrade"
  python3 "$skills_root/.system/plugin-creator/scripts/validate_plugin.py" "$repo_root"
}

run_group static static_checks
run_group core core_checks
run_group compatibility compatibility_checks
run_group upgrades upgrade_checks
run_group packaging packaging_checks
run_group presentation presentation_checks

if [ "$release_mode" -eq 1 ]; then
  run_group release release_checks
else
  hermes_root="${HERMES_SOURCE_ROOT:-$HOME/.hermes/hermes-agent}"
  if [ -d "$hermes_root" ]; then
    printf 'PASS %-16s\n' 'hermes-source'
  else
    printf 'SKIP %-16s %s\n' 'hermes-source' 'use --release to require native Hermes validation'
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf 'release-readiness=failed groups=%s\n' "$failures" >&2
  exit 1
fi
printf 'release-readiness=passed mode=%s\n' "$mode"
