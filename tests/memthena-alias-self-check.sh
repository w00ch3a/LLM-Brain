#!/usr/bin/env bash
# Memthena rename: `memthena` runs the same CLI; MEMTHENA_* env vars alias
# LLM_BRAIN_* (MEMTHENA wins); on-disk layout and ids are unchanged; the codex
# marketplace ref follows VERSION.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-alias.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'memthena-alias-self-check: %s\n' "$*" >&2; exit 1; }
unset LLM_BRAIN_ROOT MEMTHENA_ROOT
[ "$("$repo_root/bin/memthena" --version)" = "$("$repo_root/bin/llm-brain" --version)" ] || fail 'version differs'
mkdir -p "$fixture/ws"
MEMTHENA_ROOT="$fixture/a" "$repo_root/bin/memthena" project ensure "$fixture/ws" --id proj_alias >/dev/null
[ -d "$fixture/a/projects/proj_alias" ] || fail 'MEMTHENA_ROOT not honoured'
LLM_BRAIN_ROOT="$fixture/b" MEMTHENA_ROOT="$fixture/c" "$repo_root/bin/llm-brain" project ensure "$fixture/ws" --id proj_alias >/dev/null
[ -d "$fixture/c/projects/proj_alias" ] && [ ! -e "$fixture/b" ] || fail 'MEMTHENA_* must win over LLM_BRAIN_*'
LLM_BRAIN_ROOT="$fixture/d" "$repo_root/bin/memthena" project ensure "$fixture/ws" --id proj_alias >/dev/null
[ -d "$fixture/d/projects/proj_alias" ] || fail 'LLM_BRAIN_ROOT must keep working'
ref="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"][0]["source"]["ref"])' "$repo_root/marketplaces/codex.json")"
[ "$ref" = "v$(tr -d '[:space:]' <"$repo_root/VERSION")" ] || fail "codex marketplace ref $ref does not match VERSION"
# The SessionStart hook and the Hermes plugin honour the aliases too.
[ -z "$(MEMTHENA_PASSIVE=0 sh "$repo_root/hooks/session-start.sh" session)" ] || fail 'hook ignored MEMTHENA_PASSIVE'
MEMTHENA_ROOT="$fixture/h" python3 - "$repo_root" <<'PY' || fail 'Hermes plugin ignored MEMTHENA_ROOT'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("hp", os.path.join(sys.argv[1], "integrations/hermes/llm-brain/__init__.py"))
try:
    hp = importlib.util.module_from_spec(spec); spec.loader.exec_module(hp)
except ImportError:
    sys.exit(0)  # needs a Hermes host
sys.exit(0 if hp._default_vault() == os.environ["MEMTHENA_ROOT"] else 1)
PY
printf 'memthena-alias-self-check: ok\n'
