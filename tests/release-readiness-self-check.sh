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

run_steps() {
  local -a step=()
  local argument
  for argument in "$@"; do
    if [ "$argument" = "--" ]; then
      [ "${#step[@]}" -gt 0 ] || return 64
      if ! "${step[@]}"; then
        return 1
      fi
      step=()
    else
      step[${#step[@]}]="$argument"
    fi
  done
  [ "${#step[@]}" -eq 0 ] || "${step[@]}"
}

static_checks() {
  run_steps \
    bash -n "$repo_root/bin/llm-brain" -- \
    python3 -m py_compile "$repo_root/lib/okf.py"
  while IFS= read -r -d '' test_file; do
    if ! bash -n "$test_file"; then
      return 1
    fi
  done < <(find "$repo_root/tests" -type f -name '*self-check.sh' -print0)
  git -C "$repo_root" diff --check
}

core_checks() {
  run_steps \
    bash "$repo_root/tests/release-runner-self-check.sh" -- \
    bash "$repo_root/tests/self-check.sh" -- \
    bash "$repo_root/tests/okf-self-check.sh" -- \
    bash "$repo_root/tests/v3-self-check.sh" -- \
    bash "$repo_root/tests/reflection-scheduler-self-check.sh" -- \
    bash "$repo_root/tests/work-self-check.sh" -- \
    bash "$repo_root/tests/state-commitment-capsule-self-check.sh" -- \
    bash "$repo_root/tests/temporal-self-check.sh" -- \
    bash "$repo_root/tests/retrieval-planner-self-check.sh" -- \
    bash "$repo_root/tests/procedure-run-self-check.sh" -- \
    bash "$repo_root/tests/reconsolidation-self-check.sh" -- \
    bash "$repo_root/tests/scope-feedback-self-check.sh" -- \
    bash "$repo_root/tests/experimental-gates-self-check.sh" -- \
    bash "$repo_root/tests/research-upgrades-self-check.sh" -- \
    bash "$repo_root/tests/lifecycle-eval-self-check.sh" -- \
    bash "$repo_root/tests/eval-self-check.sh"
}

compatibility_checks() {
  run_steps \
    bash "$repo_root/tests/compatibility-self-check.sh" -- \
    bash "$repo_root/tests/hermes-integration-self-check.sh"
}

upgrade_checks() {
  bash "$repo_root/tests/upgrade-self-check.sh"
}

packaging_checks() {
  run_steps \
    bash "$repo_root/scripts/package-ai-skill.sh" -- \
    verify_ai_packages -- \
    bash "$repo_root/tests/automatic-use-self-check.sh"
}

verify_ai_packages() {
  local version archive_path archive checksum expected actual temporary
  version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
  for archive in plugin standalone; do
    case "$archive" in
      plugin) archive_path="${repo_root}/dist/llm-brain-${version}-plugin.tar.gz" ;;
      standalone) archive_path="${repo_root}/dist/llm-brain-${version}-standalone.tar.gz" ;;
    esac
    checksum="${archive_path}.sha256"
    [ -f "$archive_path" ] || { printf 'missing package archive: %s\n' "$archive_path" >&2; return 1; }
    [ -f "$checksum" ] || { printf 'missing package checksum: %s\n' "$checksum" >&2; return 1; }
    expected="$(awk '{print $1; exit}' "$checksum")"
    actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || { printf 'package checksum mismatch: %s\n' "$archive_path" >&2; return 1; }
    (cd "$(dirname "$archive_path")" && shasum -a 256 -c "$(basename "$checksum")" >/dev/null) || return 1
  done
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-package-check.XXXXXX")"
  tar -xzf "$repo_root/dist/llm-brain-${version}-plugin.tar.gz" -C "$temporary" || { rm -rf "$temporary"; return 1; }
  tar -xzf "$repo_root/dist/llm-brain-${version}-standalone.tar.gz" -C "$temporary" || { rm -rf "$temporary"; return 1; }
  [ "$("$temporary/llm-brain/skills/llm-brain/scripts/llm-brain" --version)" = "$version" ] || { rm -rf "$temporary"; return 1; }
  [ "$("$temporary/llm-brain/bin/llm-brain" --version)" = "$version" ] || { rm -rf "$temporary"; return 1; }
  if ! python3 - "$temporary" "$version" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "llm-brain"
version = sys.argv[2]
for relative in (".codex-plugin/plugin.json", ".claude-plugin/plugin.json", "gemini-extension.json"):
    if json.loads((root / relative).read_text(encoding="utf-8"))["version"] != version:
        raise SystemExit(f"package manifest version mismatch: {relative}")
PY
  then
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"

  # The packager already performs a byte-for-byte double build. Re-run it here
  # and compare the published archives as an independent aggregate gate so a
  # stale or manually replaced dist artifact cannot satisfy release readiness.
  local before_plugin before_standalone after_plugin after_standalone
  before_plugin="$(shasum -a 256 "$repo_root/dist/llm-brain-${version}-plugin.tar.gz" | awk '{print $1}')"
  before_standalone="$(shasum -a 256 "$repo_root/dist/llm-brain-${version}-standalone.tar.gz" | awk '{print $1}')"
  if ! bash "$repo_root/scripts/package-ai-skill.sh" >/dev/null; then
    printf 'package reproducibility rebuild failed\n' >&2
    return 1
  fi
  after_plugin="$(shasum -a 256 "$repo_root/dist/llm-brain-${version}-plugin.tar.gz" | awk '{print $1}')"
  after_standalone="$(shasum -a 256 "$repo_root/dist/llm-brain-${version}-standalone.tar.gz" | awk '{print $1}')"
  [ "$before_plugin" = "$after_plugin" ] || { printf 'plugin archive changed across rebuilds\n' >&2; return 1; }
  [ "$before_standalone" = "$after_standalone" ] || { printf 'standalone archive changed across rebuilds\n' >&2; return 1; }
  printf 'package-artifacts=verified version=%s checksums=verified reproducibility=verified\n' "$version"
}

verify_hermes_package() {
  local primary="$1" repeat="$2"
  [ -f "$primary/plugin.yaml" ] || { printf 'Hermes package manifest missing: %s\n' "$primary/plugin.yaml" >&2; return 1; }
  [ -f "$primary/README.md" ] || { printf 'Hermes package README missing: %s\n' "$primary/README.md" >&2; return 1; }
  [ -f "$primary/docs/releases/v0.6.2.md" ] || { printf 'Hermes package release notes missing: %s\n' "$primary/docs/releases/v0.6.2.md" >&2; return 1; }
  [ -f "$primary/docs/research/2026-09-06-hermes-openclaw-memory-comparison.md" ] || { printf 'Hermes package comparison report missing: %s\n' "$primary/docs/research/2026-09-06-hermes-openclaw-memory-comparison.md" >&2; return 1; }
  if ! bash "$repo_root/scripts/package-hermes-plugin.sh" "$repeat" >/dev/null; then
    printf 'Hermes package reproducibility rebuild failed\n' >&2
    return 1
  fi
  if ! python3 - "$primary" "$repeat" <<'PY'
import hashlib
import sys
from pathlib import Path


def digest(root: Path) -> str:
    records = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        if path.is_file():
            records.append(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
                f"{path.relative_to(root).as_posix()}\n"
            )
    return hashlib.sha256("".join(records).encode("utf-8")).hexdigest()


primary, repeat = map(Path, sys.argv[1:])
if digest(primary) != digest(repeat):
    raise SystemExit("Hermes package changed across reproducibility rebuilds")
PY
  then
    return 1
  fi
  printf 'hermes-package=verified version=%s reproducibility=verified\n' "$(tr -d '[:space:]' <"$repo_root/VERSION")"
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
  if ! HERMES_SOURCE_ROOT="$hermes_root" bash "$repo_root/tests/hermes-integration-self-check.sh"; then
    return 1
  fi
  run_steps \
    bash "$repo_root/scripts/package-hermes-plugin.sh" "$package_dir" -- \
    grep -Fqx "version: $version" "$package_dir/plugin.yaml" -- \
    test -f "$package_dir/README.md" -- \
    python3 "$skills_root/.system/skill-creator/scripts/quick_validate.py" "$repo_root/skills/llm-brain" -- \
    python3 "$skills_root/.system/skill-creator/scripts/quick_validate.py" "$repo_root/skills/llm-brain-upgrade" -- \
    python3 "$skills_root/.system/plugin-creator/scripts/validate_plugin.py" "$repo_root"
  verify_hermes_package "$package_dir" "$fixture/hermes-package-repeat"
}

if [ "${LLM_BRAIN_RELEASE_RUNNER_SELF_TEST:-0}" = 1 ]; then
  runner_failed_step() { return 37; }
  runner_success_step() { return 0; }
  if run_steps runner_failed_step -- runner_success_step; then
    printf 'release-runner-self-test=failed\n' >&2
    exit 1
  fi
  printf 'release-runner-self-test=passed\n'
  exit 0
fi

run_group static static_checks
run_group core core_checks
run_group compatibility compatibility_checks
run_group packaging packaging_checks
run_group upgrades upgrade_checks
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
