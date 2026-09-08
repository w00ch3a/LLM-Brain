#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
release_notes="$repo_root/docs/releases/v${version}.md"
source_dir="$repo_root/integrations/hermes/llm-brain"
output_dir="${1:-$repo_root/dist/hermes/llm-brain}"

[ -f "$source_dir/__init__.py" ] || { printf 'missing Hermes plugin source\n' >&2; exit 66; }
[ -f "$source_dir/plugin.yaml" ] || { printf 'missing Hermes plugin manifest\n' >&2; exit 66; }
[ -f "$release_notes" ] || { printf 'missing release notes: %s\n' "$release_notes" >&2; exit 66; }
mkdir -p "$(dirname "$output_dir")"
stage="${output_dir}.tmp.$$"
mkdir -p "$stage/docs/releases" "$stage/docs/research"
cp "$source_dir/__init__.py" "$source_dir/README.md" "$stage/"
cp "$repo_root/docs/evaluation.md" "$stage/docs/evaluation.md"
cp "$release_notes" "$stage/docs/releases/v${version}.md"
cp "$repo_root/docs/releases/unreleased.md" "$stage/docs/releases/unreleased.md"
cp "$repo_root/docs/research/2026-09-06-hermes-openclaw-memory-comparison.md" "$stage/docs/research/2026-09-06-hermes-openclaw-memory-comparison.md"
sed "s/^version: .*/version: $version/" "$source_dir/plugin.yaml" >"$stage/plugin.yaml"
python3 - "$stage/__init__.py" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
compile(source.read_text(encoding="utf-8"), str(source), "exec")
PY
if LC_ALL=C grep -R -nE '/Users/[^$[:space:]]+|/home/[^$[:space:]]+|(^|[^0-9])(10|127|169\.254|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+' "$stage"; then
  printf 'Hermes package contains a private machine identifier\n' >&2
  exit 65
fi
if [ -e "$output_dir" ]; then
  printf 'package output already exists: %s\n' "$output_dir" >&2
  exit 73
fi
mv "$stage" "$output_dir"
printf 'hermes_package=ok version=%s path=%s\n' "$version" "$output_dir"
