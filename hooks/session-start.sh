#!/usr/bin/env sh
# Never block a Claude session. The skill performs all project-specific reads.
# Usage: session-start.sh [session|subagent] [--stdin]
#   session   SessionStart (default)
#   subagent  SubagentStart; opt-in, see below
#   --stdin   the host pipes its hook JSON on stdin (hooks.json passes this)
[ "${LLM_BRAIN_PASSIVE:-1}" = "0" ] && exit 0
mode=${1:-session}
# Read host JSON only when asked to, so a manual run never waits on stdin.
input=""
if [ "${2:-}" = "--stdin" ] && [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then input=$(timeout 1 cat 2>/dev/null || true); else input=$(cat 2>/dev/null || true); fi
fi
source_kind=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
if [ "$mode" = "subagent" ]; then
  # Sub-agent recall is opt-in (each sub-agent start costs tokens):
  # LLM_BRAIN_SUBAGENT_RECALL=1, capped by LLM_BRAIN_SUBAGENT_BYTES (1500).
  [ "${LLM_BRAIN_SUBAGENT_RECALL:-0}" = "1" ] || exit 0
else
  printf '%s\n' \
    'LLM-BRAIN AUTOMATIC USE CONTRACT: LLM-Brain is active infrastructure; only the user experience is passive. For each non-trivial project task, automatically use the llm-brain skill to resolve and retrieve relevant approved project memory before work, process bounded Markdown work items when available, then capture the authorised closeout. Current source, governing instructions, explicit user direction and live proof outrank memory. Never auto-promote protected material. Do not require the user to name LLM-Brain.'
fi
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
run_cli() {
  if command -v timeout >/dev/null 2>&1; then timeout 3 bash "$cli" "$@" 2>/dev/null; else bash "$cli" "$@" 2>/dev/null; fi
}
if [ "$mode" = "subagent" ]; then
  sub_bytes=${LLM_BRAIN_SUBAGENT_BYTES:-1500}
  case "$sub_bytes" in ''|*[!0-9]*) sub_bytes=1500 ;; esac
  brief=$(run_cli brief --source-root "$PWD" --max-bytes "$sub_bytes") || brief=""
  [ -n "$brief" ] || exit 0
  command -v python3 >/dev/null 2>&1 || exit 0
  # SubagentStart context must be returned as hookSpecificOutput JSON.
  printf '%s' "$brief" | python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "SubagentStart", "additionalContext": "LLM-Brain project memory (read-only; current source and the parent task outrank it):\n" + sys.stdin.read()}}))' 2>/dev/null || true
  exit 0
fi
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
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
        set -- "$@" --since "$since"
        # After compaction, re-attach the newest pack built since the last
        # start, once and capped. Disable with LLM_BRAIN_COMPACT_REATTACH=0.
        if [ "$source_kind" = "compact" ] && [ "${LLM_BRAIN_COMPACT_REATTACH:-1}" != "0" ]; then
          set -- "$@" --reattach-since "$since"
        fi
        ;;
    esac
    [ -z "${LLM_BRAIN_AGENT:-}" ] || set -- "$@" --session "$agent"
  fi
fi
brief=$(run_cli "$@") || brief=""
if [ -n "$brief" ]; then
  printf '\n%s\n' "$brief"
  if [ -n "$marker" ]; then
    (umask 077; mkdir -p "$state_dir" 2>/dev/null && date -u '+%Y-%m-%dT%H:%M:%SZ' >"$marker" 2>/dev/null) || true
  fi
fi
exit 0
