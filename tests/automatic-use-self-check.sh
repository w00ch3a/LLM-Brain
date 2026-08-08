#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
contract="$("$repo_root/hooks/session-start.sh")"
archive_members="$(tar -tzf "$repo_root/dist/llm-brain-${version}-plugin.tar.gz")"
standalone_members="$(tar -tzf "$repo_root/dist/llm-brain-${version}-standalone.tar.gz")"

grep -Fq 'Do not require the user to name LLM-Brain.' <<<"$contract"
[ -z "$(LLM_BRAIN_PASSIVE=0 "$repo_root/hooks/session-start.sh")" ]
grep -Fq 'LLM_BRAIN_PASSIVE=0' "$repo_root/GEMINI.md"
grep -Fq 'LLM_BRAIN_PASSIVE=0' "$repo_root/adapters/generic.md"
grep -Fq 'llm-brain-upgrade' "$repo_root/GEMINI.md"
grep -Fq 'Install it for me (Recommended)' "$repo_root/install_prompt.md"
grep -Fq 'Do not present a technical questionnaire before this choice.' "$repo_root/install_prompt.md"
grep -Fxq 'llm-brain/install_prompt.md' <<<"$archive_members"
grep -Fxq 'llm-brain/install_prompt.md' <<<"$standalone_members"
grep -Fxq 'llm-brain/hooks/session-start.sh' <<<"$archive_members"
grep -Fxq 'llm-brain/skills/llm-brain-upgrade/SKILL.md' <<<"$archive_members"

printf 'llm-brain automatic-use self-check passed\n'
