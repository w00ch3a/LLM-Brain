#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_name="llm-brain"
version="${1:-}"

manifest="$repo_root/.codex-plugin/plugin.json"
if [ "$version" = "" ]; then
  version="$(python3 - "$manifest" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["version"])
PY
)"
fi

dist_dir="$repo_root/dist"
skill_parent="$dist_dir/skill"
plugin_parent="$dist_dir/plugin"
skill_stage="$skill_parent/$plugin_name"
plugin_stage="$plugin_parent/$plugin_name"

rm -rf "$skill_parent" "$plugin_parent"
mkdir -p \
  "$skill_stage/agents" \
  "$skill_stage/scripts" \
  "$plugin_stage/.codex-plugin" \
  "$plugin_stage/skills/$plugin_name/agents" \
  "$plugin_stage/skills/$plugin_name/scripts"

python3 - "$manifest" "$plugin_stage/.codex-plugin/plugin.json" "$version" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
version = sys.argv[3]

payload = json.loads(source.read_text(encoding="utf-8"))
payload["version"] = version
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

install -m 0644 "$repo_root/SKILL.md" "$skill_stage/SKILL.md"
install -m 0644 "$repo_root/agents/openai.yaml" "$skill_stage/agents/openai.yaml"
install -m 0755 "$repo_root/bin/llm-brain" "$skill_stage/scripts/llm-brain"

install -m 0644 "$repo_root/LICENSE" "$plugin_stage/LICENSE"
install -m 0644 "$repo_root/SKILL.md" "$plugin_stage/skills/$plugin_name/SKILL.md"
install -m 0644 "$repo_root/agents/openai.yaml" "$plugin_stage/skills/$plugin_name/agents/openai.yaml"
install -m 0755 "$repo_root/bin/llm-brain" "$plugin_stage/skills/$plugin_name/scripts/llm-brain"

bash -n "$skill_stage/scripts/llm-brain"
bash -n "$plugin_stage/skills/$plugin_name/scripts/llm-brain"

skill_archive="$dist_dir/${plugin_name}-skill-${version}.tar.gz"
plugin_archive="$dist_dir/${plugin_name}-plugin-${version}.tar.gz"
rm -f "$skill_archive" "$plugin_archive" "$skill_archive.sha256" "$plugin_archive.sha256"

tar -czf "$skill_archive" -C "$skill_parent" "$plugin_name"
tar -czf "$plugin_archive" -C "$plugin_parent" "$plugin_name"

(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$skill_archive")" >"$(basename "$skill_archive").sha256"
  shasum -a 256 "$(basename "$plugin_archive")" >"$(basename "$plugin_archive").sha256"
)

printf 'package=ok type=skill file=%s\n' "$skill_archive"
printf 'package=ok type=plugin file=%s\n' "$plugin_archive"
