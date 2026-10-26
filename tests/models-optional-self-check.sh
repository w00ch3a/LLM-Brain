#!/usr/bin/env bash
# Memthena model split: the base package ships the int4 embedder and the
# linear System One fallback only; the 32m model is installed per machine by
# `models install system-one-32m` (checksum-verified, safe layout, atomic) and
# everything falls back to the linear model when it is absent or broken.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-models.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'models-optional-self-check: %s\n' "$*" >&2; exit 1; }
unset MEMTHENA_S1_MODELS_DIR LLM_BRAIN_S1_MODELS_DIR MEMTHENA_S1_BACKEND
export XDG_DATA_HOME="$fixture/data"
[ ! -e "$repo_root/models/memthena-s1-32m-int8" ] || fail 'the 32m model must not be in the base models/ folder'
[ -f "$repo_root/models/memthena-s1-lin/memthena-s1-lin.s1lin" ] && [ -f "$repo_root/models/lbembed-v2-int4.bin" ] || fail 'base models missing'
status="$("$cli" models status)"
grep -q 'system_one_32m=absent' <<<"$status" && grep -q 'active=memthena-s1-lin' <<<"$status" && grep -q 'embedder=lbembed-v2-int4' <<<"$status" || fail "status without 32m: $status"
# A fake (tiny) 32m asset in the release layout.
mk_asset() { # dir-name extra
  rm -rf "$fixture/src"; mkdir -p "$fixture/src/$1/tokenizer"
  printf 'not-a-real-onnx' >"$fixture/src/$1/memthena-s1-32m.int8.onnx"
  printf '{"temps": {}}' >"$fixture/src/$1/meta.json"; printf '{}' >"$fixture/src/$1/tokenizer/tokenizer.json"
  tar -czf "$fixture/asset.tar.gz" -C "$fixture/src" "$1"
  (cd "$fixture" && sha256sum asset.tar.gz 2>/dev/null || shasum -a 256 asset.tar.gz) | awk '{print $1 "  asset.tar.gz"}' >"$fixture/asset.tar.gz.sha256"
}
mk_asset memthena-s1-32m-int8
! "$cli" models install system-one-32m --archive "$fixture/asset.tar.gz" --sha256 0000 >/dev/null 2>&1 || fail 'checksum mismatch accepted'
[ ! -e "$XDG_DATA_HOME/llm-brain/models/memthena-s1-32m-int8" ] || fail 'mismatch left files behind'
mk_asset evil; ! "$cli" models install system-one-32m --archive "$fixture/asset.tar.gz" >/dev/null 2>&1 || fail 'unexpected layout accepted'
mk_asset memthena-s1-32m-int8
"$cli" models install system-one-32m --archive "$fixture/asset.tar.gz" | grep -q '^models=installed' || fail 'install failed'
[ -f "$XDG_DATA_HOME/llm-brain/models/memthena-s1-32m-int8/meta.json" ] || fail 'not installed per machine'
grep -q 'system_one_32m=installed' <<<"$("$cli" models status)" || fail 'status does not see the install'
# Broken or runtime-less 32m: System One still loads the linear model (fail-open).
python3 - "$repo_root" <<'PY' || fail 'no linear fallback with a broken 32m install'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib")); import memthena_s1 as s1
assert s1.installed_32m(), "installed_32m"
p = s1.load_predictor("bundled")
assert isinstance(p, s1.LinPred) and s1.acting(p) == {"dup"}, type(p)
PY
# Download path (release base URL), then remove.
mkdir -p "$fixture/rel/v$(tr -d '[:space:]' <"$repo_root/VERSION")"
v="$(tr -d '[:space:]' <"$repo_root/VERSION")"
cp "$fixture/asset.tar.gz" "$fixture/rel/v$v/llm-brain-$v-system-one-32m.tar.gz"
awk '{print $1}' "$fixture/asset.tar.gz.sha256" >"$fixture/rel/v$v/llm-brain-$v-system-one-32m.tar.gz.sha256"
"$cli" models remove system-one-32m | grep -q 'models=removed' || fail 'remove failed'
grep -q 'active=memthena-s1-lin' <<<"$("$cli" models status)" || fail 'not back on linear after remove'
LLM_BRAIN_RELEASE_BASE_URL="file://$fixture/rel" "$cli" models install system-one-32m | grep -q '^models=installed' || fail 'download install failed'
! LLM_BRAIN_RELEASE_BASE_URL="file://$fixture/none" "$cli" models install system-one-32m >/dev/null 2>&1 || fail 'missing asset must fail'
[ -f "$XDG_DATA_HOME/llm-brain/models/memthena-s1-32m-int8/meta.json" ] || fail 'failed download removed the existing install'
printf 'models-optional-self-check: ok\n'
