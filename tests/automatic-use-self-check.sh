#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contract="$("$repo_root/hooks/session-start.sh")"
archive_members="$(tar -tzf "$repo_root/dist/llm-brain-0.4.0-plugin.tar.gz")"

grep -Fq 'Do not require the user to name LLM-Brain.' <<<"$contract"
[ -z "$(LLM_BRAIN_PASSIVE=0 "$repo_root/hooks/session-start.sh")" ]
grep -Fq 'LLM_BRAIN_PASSIVE=0' "$repo_root/GEMINI.md"
grep -Fq 'LLM_BRAIN_PASSIVE=0' "$repo_root/adapters/generic.md"
grep -Fq 'llm-brain-upgrade' "$repo_root/GEMINI.md"
grep -Fxq 'llm-brain/hooks/session-start.sh' <<<"$archive_members"
grep -Fxq 'llm-brain/skills/llm-brain-upgrade/SKILL.md' <<<"$archive_members"

printf 'llm-brain automatic-use self-check passed\n'
