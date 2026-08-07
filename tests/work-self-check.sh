#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-work.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_work_self_check"
mkdir -p "$vault"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null

cat >"$fixture/provider.sh" <<'PROVIDER'
#!/usr/bin/env bash
if [ "${LLM_BRAIN_WORK_TEST_SLEEP:-0}" != "0" ]; then sleep "$LLM_BRAIN_WORK_TEST_SLEEP"; fi
exit 0
PROVIDER
chmod 755 "$fixture/provider.sh"

for name in one two three; do
  printf 'episode %s\n' "$name" >"$fixture/$name.md"
done
printf 'episode four\n' >"$fixture/four.md"

for name in one two; do
  LLM_BRAIN_WORK_AUTORUN=0 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/$name.md" --provider "$fixture/provider.sh" >"$fixture/$name.out"
  grep -Fq 'reflection=queued reason=async-work' "$fixture/$name.out"
done

pending="$($cli --root "$vault" work status "$project_id")"
[ "$(printf '%s\n' "$pending" | awk -F '\t' '$2 == "pending" { count += 1 } END { print count + 0 }')" = 2 ] || exit 1

LLM_BRAIN_WORK_TEST_SLEEP=1 "$cli" --root "$vault" work run-once "$project_id" >"$fixture/worker-one.out" &
worker_one=$!
LLM_BRAIN_WORK_TEST_SLEEP=1 "$cli" --root "$vault" work run-once "$project_id" >"$fixture/worker-two.out" &
worker_two=$!
wait "$worker_one"
wait "$worker_two"

status="$($cli --root "$vault" work status "$project_id")"
[ "$(printf '%s\n' "$status" | awk -F '\t' '$2 == "committed" { count += 1 } END { print count + 0 }')" = 2 ] || exit 1
! grep -R 'lock held' "$fixture" >/dev/null 2>&1
! find "$vault/projects/$project_id" -type f \( -name '*.tmp.*' -o -name '.incoming.*' \) -print -quit | grep -q .

captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/three.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
episode_ref="${episode_file#"$vault/projects/$project_id/"}"
queued="$($cli --root "$vault" work enqueue "$project_id" reflect "$episode_ref" --provider "$fixture/provider.sh")"
request_file="$(printf '%s\n' "$queued" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"

awk '
  /^brain_request_state:/ { print "brain_request_state: running"; next }
  /^brain_owner_pid:/ { print "brain_owner_pid: 999999"; next }
  { print }
' "$request_file" >"$request_file.tmp"
mv "$request_file.tmp" "$request_file"
$cli --root "$vault" work recover "$project_id" >/dev/null
grep -Fq 'brain_request_state: pending' "$request_file"
grep -Fq 'brain_error: worker-lost' "$request_file"

LLM_BRAIN_WORK_AUTORUN=1 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/four.md" --provider "$fixture/provider.sh" >"$fixture/four.out"
grep -Fq 'reflection=queued reason=async-work' "$fixture/four.out"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s\n' "$($cli --root "$vault" work status "$project_id")" | awk -F '\t' '$2 == "committed" && $3 == "reflect" { count += 1 } END { exit !(count >= 3) }' && break
  sleep 0.2
done
printf '%s\n' "$($cli --root "$vault" work status "$project_id")" | awk -F '\t' '$2 == "committed" && $3 == "reflect" { count += 1 } END { exit !(count >= 3) }'

printf '%s\n' 'llm-brain work self-check passed'
