#!/usr/bin/env bash
# Shared-NAS locks: another host's live lock is never stolen (its pid means
# nothing here); it is recovered only after LOCK_STALE_SECONDS of silence.
# Legacy owners (no host_id) with a pid dead locally fall back to their age.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-lock-host.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
set_mtime() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

vault="$fixture/vault"; workspace="$fixture/ws"; mkdir -p "$workspace"
project_id="proj_lock_host"
LLM_BRAIN_HOST_ID=machine-a "$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
lock="$vault/.locks/project-$project_id.lock"
dead_pid=999999; while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
other_host="$(python3 -c 'import hashlib;print(hashlib.sha256(b"x").hexdigest()[:16])')"

write_owner() { # host pid epoch
  mkdir -p "$lock"
  { printf 'pid=%s\nprocess_start=\ntimestamp=%s\nactor=test\ntoken=t%s\n' "$2" "$(iso "$3")" "$RANDOM"
    [ -z "$1" ] || printf 'host_id=%s\n' "$1"; } >"$lock/owner"
  set_mtime "$lock/owner" "$3"; set_mtime "$lock" "$3"
}
try_write() { # expect(ok|held) id
  if LLM_BRAIN_HOST_ID=machine-a LLM_BRAIN_LOCK_WAIT_SECONDS=2 LLM_BRAIN_LOCK_STALE_SECONDS=300 \
      "$cli" --root "$vault" topic add "$project_id" "Lock $2" --id "$2" >/dev/null 2>"$fixture/err"; then
    [ "$1" = ok ] || { printf 'lock stolen: %s\n' "$2" >&2; exit 1; }
  else
    [ "$1" = held ] && grep -q 'lock held after' "$fixture/err" || { cat "$fixture/err" >&2; printf 'unexpected: %s\n' "$2" >&2; exit 1; }
  fi
}
now="$(date +%s)"

# 1. Another host, pid dead *here*, fresh heartbeat: must be respected.
write_owner "$other_host" "$dead_pid" "$now"; try_write held other-fresh
[ -f "$lock/owner" ] || { echo 'fresh foreign lock removed' >&2; exit 1; }
# 2. Another host, pid alive here (pid 1), silent for an hour: recovered.
write_owner "$other_host" 1 "$((now - 3600))"; try_write ok other-stale
[ ! -d "$lock" ] || { echo 'stale foreign lock left' >&2; exit 1; }
# 3. Legacy owner (no host_id), dead pid, fresh timestamp: respected.
write_owner "" "$dead_pid" "$now"; try_write held legacy-fresh
# 4. Legacy owner, dead pid, old timestamp: recovered.
write_owner "" "$dead_pid" "$((now - 3600))"; try_write ok legacy-stale
# 5. Same host, dead pid: recovered immediately (old behaviour kept).
own="$(LLM_BRAIN_HOST_ID=machine-a bash -c 'printf "llm-brain-lock-host|machine-a" | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; } | cut -c1-16')"
write_owner "$own" "$dead_pid" "$now"; try_write ok same-dead
# 6. Recovery records keep the recovered owner metadata (incl. host_id).
grep -q '^host_id=' "$vault/.locks/"project-"$project_id".recovered.* || { echo 'recovery record lacks owner metadata' >&2; exit 1; }

printf '%s\n' 'llm-brain lock host self-check passed'
