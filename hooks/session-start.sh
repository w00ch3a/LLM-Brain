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
set -- brief --source-root "$PWD" --max-bytes "$brief_bytes"
# Session handover: a host-side marker (outside the vault) remembers when this
# agent last started here, so the brief can say what changed since then.
# Disable with LLM_BRAIN_HANDOVER=0.
marker=""
if [ "${LLM_BRAIN_HANDOVER:-1}" != "0" ]; then
  agent=${LLM_BRAIN_AGENT:-claude-code}
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/llm-brain/sessions
  key=$(printf '%s|%s' "$PWD" "$agent" | cksum 2>/dev/null | awk '{ print $1 }')
  if [ -n "$key" ]; then
    marker="$state_dir/$key"
    since=$(head -n 1 "$marker" 2>/dev/null || true)
    case "$since" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) set -- "$@" --since "$since" ;;
    esac
    [ -z "${LLM_BRAIN_AGENT:-}" ] || set -- "$@" --session "$agent"
  fi
fi
if command -v timeout >/dev/null 2>&1; then
  brief=$(timeout 3 bash "$cli" "$@" 2>/dev/null) || brief=""
else
  brief=$(bash "$cli" "$@" 2>/dev/null) || brief=""
fi
if [ -n "$brief" ]; then
  printf '\n%s\n' "$brief"
  if [ -n "$marker" ]; then
    (umask 077; mkdir -p "$state_dir" 2>/dev/null && date -u '+%Y-%m-%dT%H:%M:%SZ' >"$marker" 2>/dev/null) || true
  fi
fi
exit 0
