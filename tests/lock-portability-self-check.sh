#!/usr/bin/env bash
# lock_mtime must return a bare epoch integer on GNU/Linux and BSD/macOS stat,
# so ownerless stale project locks are recovered on both platforms.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-lock-portability.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Emulate both stat dialects so each platform's behaviour is tested anywhere.
mkdir -p "$fixture/gnu" "$fixture/bsd"
cat >"$fixture/gnu/stat" <<'SH'
#!/usr/bin/env bash
# GNU coreutils: -f is --file-system; '%m' is then an unknown FILE operand.
if [ "$1" = -f ]; then
  printf '  File: "%s"\n    ID: 0 Namelen: 255     Type: ext2/ext3\n' "$3"
  printf "stat: cannot read file system information for '%s'\n" "$2" >&2
  exit 1
fi
[ "$1" = -c ] && [ "$2" = %Y ] || exit 2
exec python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$3"
SH
cat >"$fixture/bsd/stat" <<'SH'
#!/usr/bin/env bash
# BSD/macOS: -c is an illegal option; -f takes a format.
if [ "$1" = -c ]; then printf 'stat: illegal option -- c\n' >&2; exit 1; fi
[ "$1" = -f ] && [ "$2" = %m ] || exit 2
exec python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$3"
SH
chmod +x "$fixture/gnu/stat" "$fixture/bsd/stat"

set_mtime() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
eval "$(sed -n '/^lock_mtime() {/,/^}/p' "$cli")"
probe="$fixture/probe.lock"
mkdir "$probe"
set_mtime "$probe" 1577836800

for dialect in native gnu bsd; do
  if [ "$dialect" = native ]; then path="$PATH"; else path="$fixture/$dialect:$PATH"; fi
  value="$(PATH="$path" lock_mtime "$probe")"
  [ "$value" = 1577836800 ] || { printf 'lock_mtime(%s) returned %q\n' "$dialect" "$value" >&2; exit 1; }
  [ "$(PATH="$path" lock_mtime "$fixture/missing")" = 0 ] || { printf 'lock_mtime(%s) missing path\n' "$dialect" >&2; exit 1; }
done

# End to end: an ownerless lock older than the stale threshold is recovered;
# a fresh one is still respected and times out instead of being stolen.
for dialect in native gnu bsd; do
  if [ "$dialect" = native ]; then path="$PATH"; else path="$fixture/$dialect:$PATH"; fi
  vault="$fixture/vault-$dialect"
  workspace="$fixture/workspace-$dialect"
  mkdir -p "$workspace"
  project_id="proj_lock_$dialect"
  PATH="$path" "$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
  lock="$vault/.locks/project-$project_id.lock"
  mkdir -p "$lock"
  set_mtime "$lock" "$(( $(date +%s) - 3600 ))"
  PATH="$path" LLM_BRAIN_LOCK_WAIT_SECONDS=5 LLM_BRAIN_LOCK_STALE_SECONDS=300 \
    "$cli" --root "$vault" topic add "$project_id" "Stale lock recovery" --id stale-lock-recovery >/dev/null ||
    { printf 'stale ownerless lock was not recovered (%s)\n' "$dialect" >&2; exit 1; }
  [ ! -d "$lock" ] || { printf 'lock directory left behind (%s)\n' "$dialect" >&2; exit 1; }
  ls "$vault/.locks/" | grep -q "^project-$project_id.recovered\." ||
    { printf 'missing lock recovery record (%s)\n' "$dialect" >&2; exit 1; }

  mkdir -p "$lock"
  if PATH="$path" LLM_BRAIN_LOCK_WAIT_SECONDS=2 LLM_BRAIN_LOCK_STALE_SECONDS=300 \
    "$cli" --root "$vault" topic add "$project_id" "Fresh lock" --id fresh-lock >/dev/null 2>"$fixture/fresh.err"; then
    printf 'fresh ownerless lock was stolen (%s)\n' "$dialect" >&2; exit 1
  fi
  grep -q 'lock held after' "$fixture/fresh.err" || { cat "$fixture/fresh.err" >&2; exit 1; }
  [ -d "$lock" ] || { printf 'fresh lock removed (%s)\n' "$dialect" >&2; exit 1; }
  rmdir "$lock"
done

printf '%s\n' 'llm-brain lock portability self-check passed'
