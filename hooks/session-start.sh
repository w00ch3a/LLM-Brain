#!/usr/bin/env sh
# Never block a Claude session. The skill performs all project-specific reads.
[ "${LLM_BRAIN_PASSIVE:-1}" = "0" ] && exit 0
printf '%s\n' \
  'LLM-BRAIN AUTOMATIC USE CONTRACT: LLM-Brain is active infrastructure; only the user experience is passive. For each non-trivial project task, automatically use the llm-brain skill to resolve and retrieve relevant approved project memory before work, process bounded Markdown work items when available, then capture the authorised closeout. Current source, governing instructions, explicit user direction and live proof outrank memory. Never auto-promote protected material. Do not require the user to name LLM-Brain.'
# Optional size-capped project brief (read-only, derived, fail-open).
# Disable with LLM_BRAIN_SESSION_BRIEF=0.
[ "${LLM_BRAIN_SESSION_BRIEF:-1}" = "0" ] && exit 0
hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
cli=""
for candidate in "$hook_dir/../skills/llm-brain/scripts/llm-brain" "$hook_dir/../bin/llm-brain"; do
  if [ -f "$candidate" ]; then cli=$candidate; break; fi
done
[ -n "$cli" ] || cli=$(command -v llm-brain 2>/dev/null) || exit 0
[ -n "$cli" ] || exit 0
command -v bash >/dev/null 2>&1 || exit 0
brief_bytes=${LLM_BRAIN_SESSION_BRIEF_BYTES:-4000}
case "$brief_bytes" in ''|*[!0-9]*) brief_bytes=4000 ;; esac
if command -v timeout >/dev/null 2>&1; then
  brief=$(timeout 3 bash "$cli" brief --source-root "$PWD" --max-bytes "$brief_bytes" 2>/dev/null) || brief=""
else
  brief=$(bash "$cli" brief --source-root "$PWD" --max-bytes "$brief_bytes" 2>/dev/null) || brief=""
fi
[ -n "$brief" ] && printf '\n%s\n' "$brief"
exit 0
