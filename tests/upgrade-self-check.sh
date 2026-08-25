#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="$repo_root/bin/llm-brain"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'upgrade self-check: %s\n' "$*" >&2; exit 1; }
contains_file() { grep -Fq "$2" "$1" || fail "expected $2 in $1"; }

tree_hash() {
  local root="$1"
  (
    cd "$root"
    find . -type f | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\t' "$file"
      shasum -a 256 "$file" | awk '{print $1}'
    done
  ) | shasum -a 256 | awk '{print $1}'
}

make_runtime() {
  local home="$1" data="$2" real_python yaml_parent wrapper
  real_python="$(command -v python3)"
  yaml_parent="$("$real_python" -c 'import os, yaml; print(os.path.dirname(os.path.dirname(yaml.__file__)))')"
  wrapper="$data/llm-brain/runtimes/$version/bin/python"
  mkdir -p "$(dirname "$wrapper")" "$home"
  cat >"$wrapper" <<WRAPPER
#!/bin/sh
export PYTHONPATH="$yaml_parent\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$real_python" "\$@"
WRAPPER
  chmod +x "$wrapper"
}

make_vault() {
  local root="$1" schema="$2" project_repo="$3"
  mkdir -p "$project_repo"
  git -C "$project_repo" init -q
  LLM_BRAIN_OKF_PYTHON="$(command -v python3)" "$cli" --root "$root" project ensure "$project_repo" --id "proj_schema_${schema}" >/dev/null
  printf '%s\n' "$schema" >"$root/projects/proj_schema_${schema}/schema.version"
}

make_case() {
  local name="$1"
  case_dir="$fixture/$name"
  case_home="$case_dir/home"
  case_data="$case_dir/data"
  case_state="$case_dir/state"
  case_backups="$case_dir/backups"
  case_vault1="$case_dir/vault-one"
  case_vault2="$case_dir/vault-two"
  case_vault3="$case_dir/vault-three"
  mkdir -p "$case_dir" "$case_state" "$case_backups"
  make_runtime "$case_home" "$case_data"
  make_vault "$case_vault1" 1 "$case_dir/repo-one"
  make_vault "$case_vault2" 2 "$case_dir/repo-two"
  make_vault "$case_vault3" 3 "$case_dir/repo-three"
  mkdir -p "$case_state/llm-brain"
  printf 'schema_version\troot\tkind\tstatus\tupdated_at\n3\t%s\tshared\tactive\t2026-07-31T00:00:00Z\n3\t%s\tshared\tactive\t2026-07-31T00:00:00Z\n3\t%s\tshared\tactive\t2026-07-31T00:00:00Z\n' \
    "$case_vault1" "$case_vault2" "$case_vault3" >"$case_state/llm-brain/roots.tsv"
}

upgrade_env() {
  HOME="$case_home" \
  XDG_DATA_HOME="$case_data" \
  XDG_STATE_HOME="$case_state" \
  LLM_BRAIN_ROOT="$case_vault1" \
  LLM_BRAIN_BACKUP_ROOT="$case_backups" \
  LLM_BRAIN_STANDALONE_ROOT="$case_home/standalone" \
  LLM_BRAIN_UPGRADE_SOURCE="$repo_root" \
  LLM_BRAIN_GENERIC_INSTRUCTIONS="$case_home/global/AGENTS.md" \
  "$@"
}

plan_hash() {
  upgrade_env "$cli" upgrade check --all --host "$1" --target "$version" |
    sed -n 's/^plan_hash=//p'
}

assert_failure_rolls_back() {
  local point="$1" before1 before2 before3 hash original_adapter=""
  make_case "failure-${point//:/-}"
  if [ "$point" = "staging-verification:1" ]; then
    original_adapter="$case_dir/original-adapter"
    mkdir -p "$case_home/global"
    printf 'existing global instructions\n' >"$original_adapter"
    cp "$original_adapter" "$case_home/global/AGENTS.md"
  fi
  before1="$(tree_hash "$case_vault1")"
  before2="$(tree_hash "$case_vault2")"
  before3="$(tree_hash "$case_vault3")"
  hash="$(plan_hash standalone)"
  if LLM_BRAIN_UPGRADE_FAIL_AT="$point" upgrade_env "$cli" upgrade apply --all \
      --host standalone --target "$version" --plan-hash "$hash" \
      --root "$case_vault1" --root "$case_vault2" >/dev/null 2>&1; then
    fail "injected failure passed: $point"
  fi
  [ "$(tree_hash "$case_vault1")" = "$before1" ] || fail "$point changed schema-1 vault"
  [ "$(tree_hash "$case_vault2")" = "$before2" ] || fail "$point changed schema-2 vault"
  [ "$(tree_hash "$case_vault3")" = "$before3" ] || fail "$point changed schema-3 vault"
  [ ! -L "$case_home/.local/bin/llm-brain" ] || fail "$point left standalone launcher active"
  if [ -n "$original_adapter" ]; then
    cmp "$original_adapter" "$case_home/global/AGENTS.md" >/dev/null || fail "$point did not restore the existing generic adapter"
  else
    [ ! -e "$case_home/global/AGENTS.md" ] || fail "$point left generic adapter active"
  fi
}

for point in dependency-install package-update staging-verification:1 staging-verification:2 cutover:1 cutover:2 unexpected-exit final-verification; do
  assert_failure_rolls_back "$point"
done

make_case success
before1="$(tree_hash "$case_vault1")"
before2="$(tree_hash "$case_vault2")"
before3="$(tree_hash "$case_vault3")"
hash="$(plan_hash standalone)"
apply_output="$(upgrade_env "$cli" upgrade apply --all --host standalone --target "$version" \
  --plan-hash "$hash" --root "$case_vault1" --root "$case_vault2")"
receipt="$(printf '%s\n' "$apply_output" | sed -n 's/.*receipt=\([^ ]*\).*/\1/p' | tail -1)"
[ -f "$receipt" ] || fail "successful apply did not produce a receipt"
contains_file "$receipt" $'receipt\tcurrent_package_checksum\t'
contains_file "$receipt" $'receipt\ttarget_package_checksum\t'
[ "$("$case_home/.local/bin/llm-brain" --version)" = "$version" ] || fail "standalone version verification failed"
[ "$(cat "$case_vault1/projects/proj_schema_1/schema.version")" = 3 ] || fail "schema 1 was not upgraded"
[ "$(cat "$case_vault2/projects/proj_schema_2/schema.version")" = 3 ] || fail "schema 2 was not upgraded"
[ "$(cat "$case_vault3/projects/proj_schema_3/schema.version")" = 3 ] || fail "schema 3 changed version"
cmp "$repo_root/adapters/generic.md" "$case_home/global/AGENTS.md" >/dev/null || fail "generic adapter was not installed"
verify_hash1="$(tree_hash "$case_vault1")"
verify_hash2="$(tree_hash "$case_vault2")"
verify_hash3="$(tree_hash "$case_vault3")"
upgrade_env "$cli" upgrade verify --receipt "$receipt" >/dev/null
[ "$(tree_hash "$case_vault1")" = "$verify_hash1" ] || fail "upgrade verify mutated schema-1 vault"
[ "$(tree_hash "$case_vault2")" = "$verify_hash2" ] || fail "upgrade verify mutated schema-2 vault"
[ "$(tree_hash "$case_vault3")" = "$verify_hash3" ] || fail "upgrade verify mutated schema-3 vault"
installed_plan="$(upgrade_env "$case_home/.local/bin/llm-brain" upgrade check --all --host standalone --target "$version" --root "$case_vault1" --root "$case_vault2" | sed -n 's/^plan_hash=//p')"
printf '%s' "$installed_plan" | grep -Eq '^[a-f0-9]{64}$' || fail "installed standalone package root was not usable"
drift_file="$case_vault1/projects/proj_schema_1/okf/project.md"
cp "$drift_file" "$case_dir/project.before-rollback-drift"
printf '\n' >>"$drift_file"
if upgrade_env "$cli" upgrade rollback --receipt "$receipt" >/dev/null 2>&1; then
  fail "explicit rollback accepted a drifted vault"
fi
[ "$(tree_hash "$case_vault2")" = "$verify_hash2" ] || fail "failed rollback changed an unaffected vault"
[ "$(tree_hash "$case_vault3")" = "$verify_hash3" ] || fail "failed rollback changed schema-3 vault"
cmp "$repo_root/adapters/generic.md" "$case_home/global/AGENTS.md" >/dev/null || fail "failed rollback changed the generic adapter"
cp "$case_dir/project.before-rollback-drift" "$drift_file"
upgrade_env "$cli" upgrade rollback --receipt "$receipt" >/dev/null
[ "$(tree_hash "$case_vault1")" = "$before1" ] || fail "explicit rollback did not restore schema-1 vault"
[ "$(tree_hash "$case_vault2")" = "$before2" ] || fail "explicit rollback did not restore schema-2 vault"
[ "$(tree_hash "$case_vault3")" = "$before3" ] || fail "explicit rollback did not restore schema-3 vault"
[ ! -L "$case_home/.local/bin/llm-brain" ] || fail "explicit rollback did not restore launcher"
[ ! -e "$case_home/global/AGENTS.md" ] || fail "explicit rollback did not restore generic adapter"
contains_file "$receipt" $'receipt\tstatus\trolled-back'

make_host_stub() {
  local host="$1" source_type="$2" stub
  stub="$case_dir/bin/$host"
  mkdir -p "$(dirname "$stub")" "$case_dir/current-package/skills/llm-brain/scripts"
  cp "$cli" "$case_dir/current-package/skills/llm-brain/scripts/llm-brain"
  chmod +x "$case_dir/current-package/skills/llm-brain/scripts/llm-brain"
  printf '0.5.3\n' >"$case_dir/current-package/VERSION"
  case "$host" in
    codex)
      mkdir -p "$case_dir/current-package/.codex-plugin"
      printf '{"name":"llm-brain","version":"0.5.3"}\n' >"$case_dir/current-package/.codex-plugin/plugin.json"
      ;;
    claude)
      mkdir -p "$case_dir/current-package/.claude-plugin"
      printf '{"name":"llm-brain","version":"0.5.3"}\n' >"$case_dir/current-package/.claude-plugin/plugin.json"
      ;;
    gemini)
      mkdir -p "$case_home/.gemini/extensions"
      mv "$case_dir/current-package" "$case_home/.gemini/extensions/llm-brain"
      LLM_BRAIN_TEST_PACKAGE_ROOT="$case_home/.gemini/extensions/llm-brain"
      printf '{"name":"llm-brain","version":"0.5.3"}\n' >"$LLM_BRAIN_TEST_PACKAGE_ROOT/gemini-extension.json"
      printf '{"type":"git"}\n' >"$LLM_BRAIN_TEST_PACKAGE_ROOT/.gemini-extension-install.json"
      ;;
  esac
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LLM_BRAIN_TEST_HOST_LOG"
host="$(basename "$0")"
state="$LLM_BRAIN_TEST_HOST_STATE"
case "$host:$*" in
  "codex:plugin list --json"|"claude:plugin list --json")
    if [ "$host" = codex ]; then
      manifest="$LLM_BRAIN_TEST_PACKAGE_ROOT/.codex-plugin/plugin.json"
    else
      manifest="$LLM_BRAIN_TEST_PACKAGE_ROOT/.claude-plugin/plugin.json"
    fi
    version="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$manifest")"
    printf '{"installed":[{"name":"llm-brain","marketplaceName":"personal","version":"%s","source":{"source":"%s","path":"%s"}}]}\n' "$version" "$LLM_BRAIN_TEST_SOURCE_TYPE" "$LLM_BRAIN_TEST_PACKAGE_ROOT"
    ;;
  "codex:plugin add llm-brain@personal"|"claude:plugin update llm-brain@personal")
    if [ "$host" = codex ]; then
      printf '{"name":"llm-brain","version":"%s"}\n' "$LLM_BRAIN_TEST_TARGET_VERSION" >"$LLM_BRAIN_TEST_PACKAGE_ROOT/.codex-plugin/plugin.json"
    else
      printf '{"name":"llm-brain","version":"%s"}\n' "$LLM_BRAIN_TEST_TARGET_VERSION" >"$LLM_BRAIN_TEST_PACKAGE_ROOT/.claude-plugin/plugin.json"
    fi
    ;;
  "gemini:extensions update llm-brain")
    printf '{"name":"llm-brain","version":"%s"}\n' "$LLM_BRAIN_TEST_TARGET_VERSION" >"$LLM_BRAIN_TEST_PACKAGE_ROOT/gemini-extension.json"
    ;;
esac
STUB
  chmod +x "$stub"
}

assert_host_commands() {
  local host="$1" source_type="$2" hash before
  make_case "host-$host-$source_type"
  mkdir -p "$case_dir/bin"
  make_host_stub "$host" "$source_type"
  before="$(tree_hash "$case_vault1")"
  export LLM_BRAIN_TEST_HOST_LOG="$case_dir/host.log"
  export LLM_BRAIN_TEST_HOST_STATE="$case_dir/host.state"
  export LLM_BRAIN_TEST_SOURCE_TYPE="$source_type"
  export LLM_BRAIN_TEST_TARGET_VERSION="$version"
  if [ "$host" != gemini ]; then LLM_BRAIN_TEST_PACKAGE_ROOT="$case_dir/current-package"; fi
  export LLM_BRAIN_TEST_PACKAGE_ROOT
  PATH="$case_dir/bin:$PATH"
  export PATH
  hash="$(plan_hash "$host")"
  if LLM_BRAIN_UPGRADE_FAIL_AT=staging-verification:1 upgrade_env "$cli" upgrade apply --all \
      --host "$host" --target "$version" --plan-hash "$hash" \
      --root "$case_vault1" --root "$case_vault2" >/dev/null 2>&1; then
    fail "$host staging failure passed"
  fi
  [ "$(tree_hash "$case_vault1")" = "$before" ] || fail "$host failure changed vault"
  [ ! -e "$case_home/global/AGENTS.md" ] || fail "$host failure left generic adapter active"
  case "$host" in
    codex) contains_file "$LLM_BRAIN_TEST_PACKAGE_ROOT/.codex-plugin/plugin.json" '"version":"0.5.3"' ;;
    claude) contains_file "$LLM_BRAIN_TEST_PACKAGE_ROOT/.claude-plugin/plugin.json" '"version":"0.5.3"' ;;
    gemini) contains_file "$LLM_BRAIN_TEST_PACKAGE_ROOT/gemini-extension.json" '"version":"0.5.3"' ;;
  esac
  case "$host:$source_type" in
    codex:local)
      contains_file "$case_dir/host.log" 'plugin add llm-brain@personal'
      if grep -Fq 'plugin marketplace upgrade' "$case_dir/host.log"; then fail "local Codex marketplace used a Git refresh"; fi
      ;;
    codex:git)
      contains_file "$case_dir/host.log" 'plugin marketplace upgrade personal'
      contains_file "$case_dir/host.log" 'plugin add llm-brain@personal'
      ;;
    claude:*) contains_file "$case_dir/host.log" 'plugin update llm-brain@personal' ;;
    gemini:*) contains_file "$case_dir/host.log" 'extensions update llm-brain' ;;
  esac
  [ "$host" = gemini ] || contains_file "$case_dir/host.log" 'plugin list --json'
  unset LLM_BRAIN_TEST_HOST_LOG LLM_BRAIN_TEST_HOST_STATE LLM_BRAIN_TEST_PACKAGE_ROOT LLM_BRAIN_TEST_SOURCE_TYPE LLM_BRAIN_TEST_TARGET_VERSION
}

assert_host_commands codex local
assert_host_commands codex git
assert_host_commands claude local
assert_host_commands gemini git

make_case host-codex-git-cache-discovery
cache_root="$case_home/.codex/plugins/cache/personal/llm-brain/0.5.3"
mkdir -p "$case_dir/bin" "$cache_root/.codex-plugin" "$cache_root/skills/llm-brain/scripts"
cp "$cli" "$cache_root/skills/llm-brain/scripts/llm-brain"
chmod +x "$cache_root/skills/llm-brain/scripts/llm-brain"
printf '0.5.3\n' >"$cache_root/VERSION"
printf '{"name":"llm-brain","version":"0.5.3"}\n' >"$cache_root/.codex-plugin/plugin.json"
cat >"$case_dir/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '{"installed":[{"name":"llm-brain","marketplaceName":"personal","version":"0.5.3","source":{"source":"git","url":"https://example.invalid/llm-brain.git"}}]}\n'
STUB
chmod +x "$case_dir/bin/codex"
PATH="$case_dir/bin:$PATH" upgrade_env "$cli" upgrade check --all --host codex --target "$version" >"$case_dir/cache.out"
contains_file "$case_dir/cache.out" 'package_source_type=git'
contains_file "$case_dir/cache.out" 'target_archive_kind=plugin'
mv "$cache_root" "${cache_root}.missing"
if PATH="$case_dir/bin:$PATH" upgrade_env "$cli" upgrade check --all --host codex --target "$version" >"$case_dir/cache-missing.out" 2>&1; then
  fail "missing Codex Git cache passed preflight"
fi
contains_file "$case_dir/cache-missing.out" 'Codex plugin cache is missing'

make_case host-auto-inventory-failure
mkdir -p "$case_dir/bin"
cat >"$case_dir/bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$case_dir/bin/codex"
if PATH="$case_dir/bin:$PATH" upgrade_env "$cli" upgrade check --all --host auto --target "$version" >"$case_dir/auto.out" 2>&1; then
  fail "automatic host detection ignored a Codex inventory failure"
fi
contains_file "$case_dir/auto.out" 'unable to inspect codex plugins'

printf 'llm-brain upgrade self-check passed\n'
