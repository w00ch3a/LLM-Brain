#!/usr/bin/env bash
# #8 (2 Nov ideas): read-only snapshots of host-native memory (Claude Code,
# Codex, Hermes MEMORY.md/USER.md) into source custody with the session id,
# so changes can be seen and diffed.  Fixture homes only.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-host-memory.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset HERMES_HOME CODEX_HOME
fail() { printf 'host memory snapshot self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; home="$fixture/home"; ws="$fixture/ws"; project_id="proj_hostmem"
mkdir -p "$ws" "$home/.hermes/memories" "$home/.codex/memories" "$home/.claude"
ws="$(cd "$ws" && pwd -P)"
mkdir -p "$home/.claude/projects/$(printf '%s' "$ws" | sed 's#[^A-Za-z0-9]#-#g')/memory"
automem="$home/.claude/projects/$(printf '%s' "$ws" | sed 's#[^A-Za-z0-9]#-#g')/memory"
lb() { "$cli" --root "$vault" "$@"; }
lb project ensure "$ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"
printf 'The user prefers metric units.\n' >"$home/.hermes/memories/MEMORY.md"
printf 'Name: Sam. Timezone: Brisbane.\n' >"$home/.hermes/memories/USER.md"
printf 'Always run make test before committing.\n' >"$home/.claude/CLAUDE.md"
printf 'Build uses pnpm, not npm.\n' >"$automem/build.md"
printf 'Codex: prefer small diffs.\n' >"$home/.codex/AGENTS.md"
printf 'Project rules: no new dependencies.\n' >"$ws/AGENTS.md"
fingerprint() { find "$home" "$ws" -type f -exec sha256sum {} + | sort; find "$home" "$ws" -exec stat -c '%n %Y %a' {} + | sort; }
before="$(fingerprint)"
checks=()

out="$(lb host-memory snapshot "$project_id" --host hermes --session sess-1 --home "$home")"
grep -Fq 'files=2 changed=2' <<<"$out" || fail "hermes snapshot: $out"
lb host-memory list "$project_id" --host hermes | awk -F '\t' 'NR > 1 && $3 == "sess-1" && $7 == "new"' | grep -q MEMORY.md || fail "session id / status not recorded"
ref="$(lb host-memory list "$project_id" --host hermes --label MEMORY.md | awk -F '\t' 'NR == 2 { print $6 }')"
cmp -s "$pdir/$ref" "$home/.hermes/memories/MEMORY.md" || fail "custody copy is not byte for byte"
! grep -q "$home" "$pdir/host-memory/snapshots.tsv" || fail "manifest leaks host paths"
checks+=(hermes_snapshot=ok)

out="$(lb --cwd "$ws" host-memory snapshot auto --host claude-code --session cc-7 --home "$home" --project-root "$ws")"
grep -Fq 'files=2' <<<"$out" || fail "claude-code snapshot: $out"
lb host-memory list "$project_id" --host claude-code | grep -q $'\tauto-memory/build.md\t' || fail "auto-memory not snapshotted"
out="$(lb host-memory snapshot "$project_id" --host codex --session cx-1 --home "$home" --project-root "$ws")"
grep -Fq 'files=2' <<<"$out" || fail "codex snapshot: $out"
checks+=(claude_codex_snapshot=ok)

[ "$before" = "$(fingerprint)" ] || fail "snapshot modified host files"
checks+=(host_files_untouched=ok)

out="$(lb host-memory snapshot "$project_id" --host hermes --session sess-2 --home "$home")"
grep -Fq 'changed=0' <<<"$out" || fail "unchanged rerun reported changes: $out"
# The host quietly merges and drops a memory.
printf 'The user prefers metric units and dark mode.\n' >"$home/.hermes/memories/MEMORY.md"
rm "$home/.hermes/memories/USER.md"
out="$(lb host-memory snapshot "$project_id" --host hermes --session sess-3 --home "$home")"
grep -Fq 'changed=2' <<<"$out" || fail "change not detected: $out"
lb host-memory list "$project_id" --host hermes | awk -F '\t' '$3 == "sess-3" { print $4 ":" $7 }' | sort | tr '\n' ' ' | grep -Fq 'MEMORY.md:changed USER.md:removed' || fail "statuses wrong: $(lb host-memory list "$project_id" --host hermes)"
d="$(lb host-memory diff "$project_id" --host hermes)"
grep -Fq -- '-The user prefers metric units.' <<<"$d" && grep -Fq -- '+The user prefers metric units and dark mode.' <<<"$d" || fail "diff missing: $d"
grep -Fq 'File removed by the host.' <<<"$d" || fail "removal not shown: $d"
grep -Fq 'Name: Sam' "$pdir/$(lb host-memory list "$project_id" --host hermes --label USER.md | awk -F '\t' 'NR == 2 { print $6 }')" || fail "removed file lost from custody"
checks+=(change_and_drop_diffed=ok)

printf 'api_key = "sk-live-%s"\n' "$(printf 'A%.0s' $(seq 1 40))" >>"$home/.hermes/memories/MEMORY.md"
out="$(lb host-memory snapshot "$project_id" --host hermes --session sess-4 --home "$home")"
lb host-memory list "$project_id" --host hermes | awk -F '\t' '$3 == "sess-4" && $4 == "MEMORY.md" { print $7 }' | grep -qx blocked-secret || fail "secret-bearing memory was not blocked: $(lb host-memory list "$project_id" --host hermes | tail -2)"
! grep -rq 'sk-live-AAAA' "$pdir/sources" "$pdir/host-memory" || fail "secret copied into custody"
checks+=(secret_blocked=ok)
lb host-memory snapshot "$project_id" --host bogus 2>/dev/null && fail "unknown host accepted"
printf 'host memory snapshot self-check passed: %s\n' "${checks[*]}"
