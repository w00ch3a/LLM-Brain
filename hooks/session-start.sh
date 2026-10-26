#!/usr/bin/env sh
# Never block a Claude session. The skill performs all project-specific reads.
# Usage: session-start.sh [session|subagent] [--stdin]
#   session   SessionStart (default)
#   subagent  SubagentStart; opt-in, see below
#   --stdin   the host pipes its hook JSON on stdin (hooks.json passes this)
# Memthena env aliases (same rule as the CLI): MEMTHENA_X sets LLM_BRAIN_X.
for _mv in $(env | sed -n 's/^MEMTHENA_\([A-Z0-9_][A-Z0-9_]*\)=.*/\1/p'); do
  eval "export LLM_BRAIN_${_mv}=\"\${MEMTHENA_${_mv}}\""
done
unset _mv
# brain_applies_when "host=..." scope for the brief: the host is this agent
# (LLM_BRAIN_AGENT, default claude-code) unless LLM_BRAIN_HOST is set.
LLM_BRAIN_HOST=${LLM_BRAIN_HOST:-${LLM_BRAIN_AGENT:-claude-code}}
export LLM_BRAIN_HOST
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
# Last-good brief (outside the vault, per user): when the live brief cannot
# finish inside the hook budget (a slow NAS, a cold cache), show the last good
# one, clearly labelled, and let the live brief finish in the background so
# the next session gets a fresh copy.  Disable with LLM_BRAIN_BRIEF_FALLBACK=0.
cache_file=""
if [ "${LLM_BRAIN_BRIEF_FALLBACK:-1}" != "0" ]; then
  cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/llm-brain/briefs
  scope_key=""   # unchanged key (and cache) for the default host and no task type
  [ "$LLM_BRAIN_HOST" = "${LLM_BRAIN_AGENT:-claude-code}" ] && [ -z "${LLM_BRAIN_TASK_TYPE:-}" ] || scope_key="|$LLM_BRAIN_HOST|${LLM_BRAIN_TASK_TYPE:-}"
  cache_key=$(printf '%s|%s|%s%s' "$PWD" "$brief_bytes" "${LLM_BRAIN_AGENT:-claude-code}" "$scope_key" | cksum 2>/dev/null | awk '{ print $1 }')
  [ -z "$cache_key" ] || cache_file="$cache_dir/$cache_key"
fi
if [ -z "$cache_file" ]; then
  brief=$(run_cli "$@") || brief=""
  fresh=1
else
  (umask 077; mkdir -p "$cache_dir" 2>/dev/null) || true
  out="$cache_file.run.$$"
  busy="$cache_file.busy" already=0
  # One background refresh at a time per directory; a refresh older than
  # five minutes is presumed dead and replaced.
  [ -z "$(find "$busy" -maxdepth 0 -mmin +5 2>/dev/null)" ] || rmdir "$busy" 2>/dev/null || true
  # The background job is the only writer of the cache: it replaces the
  # cached brief atomically, and only with a complete, successful brief.
  if ! mkdir "$busy" 2>/dev/null; then
    already=1; : >"$out.done"   # a refresh is already running: use the cached brief now
  else (
    trap 'rmdir "$busy" 2>/dev/null' EXIT
    if bash "$cli" "$@" >"$out" 2>/dev/null && [ -s "$out" ]; then
      (umask 077; date -u '+%Y-%m-%dT%H:%M:%SZ' >"$out.at" && cat "$out" >>"$out.at" && mv -f "$out.at" "$cache_file") 2>/dev/null || true
      : >"$out.ok"
    fi
    : >"$out.done"
  ) </dev/null >/dev/null 2>&1 &
  fi
  waited=0 limit=${LLM_BRAIN_BRIEF_WAIT_TENTHS:-30}
  case "$limit" in ''|*[!0-9]*) limit=30 ;; esac
  while [ ! -f "$out.done" ] && [ "$waited" -lt "$limit" ]; do sleep 0.1 2>/dev/null || sleep 1; waited=$((waited + 1)); done
  brief="" fresh=0 running=1
  if [ -f "$out.done" ]; then
    running=0
    [ -f "$out.ok" ] && brief=$(cat "$out" 2>/dev/null) && fresh=1
    rm -f "$out" "$out.ok" "$out.done" 2>/dev/null
  fi
  if { [ "$running" = 1 ] || [ "$already" = 1 ]; } && [ -f "$cache_file" ]; then
    cached_at=$(head -n 1 "$cache_file" 2>/dev/null)
    brief=$(printf '(Cached brief from %s: the live brief did not finish in time and is refreshing in the background. Search before relying on details.)\n' "$cached_at"; tail -n +2 "$cache_file" 2>/dev/null)
  fi
  # A run that outlives the hook cleans up its own temp files.
  [ "$running" = 0 ] || ( while [ ! -f "$out.done" ]; do sleep 1; done; rm -f "$out" "$out.ok" "$out.done" ) </dev/null >/dev/null 2>&1 &
fi
if [ -n "$brief" ]; then
  printf '\n%s\n' "$brief"
  # Only a live brief moves the handover marker, so changes are never skipped.
  if [ -n "$marker" ] && [ "$fresh" = 1 ]; then
    (umask 077; mkdir -p "$state_dir" 2>/dev/null && date -u '+%Y-%m-%dT%H:%M:%SZ' >"$marker" 2>/dev/null) || true
  fi
fi
exit 0
