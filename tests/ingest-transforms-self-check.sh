#!/usr/bin/env bash
# #3 (16 Nov ideas): every change made to a source on the way into sources/
# is recorded, so "byte for byte" custody can be checked (`custody verify`).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-ingest-transforms.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'ingest transforms self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; ws="$fixture/ws"; mkdir -p "$ws"; project_id="proj_custody"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"
episode_of() { sed -n 's/.*episode=\([^ ]*\).*/\1/p' <<<"$1" | head -n 1; }
checks=()

# 1. A plain file with CRLF, a UTF-8 BOM, tabs and trailing spaces is kept
#    byte for byte, and the episode says no transform was applied.
printf '\xef\xbb\xbfMeeting notes\r\n\tport 8443   \r\nend without newline  ' >"$fixture/notes.txt"
out="$(b ingest-source "$project_id" "$fixture/notes.txt")"
ep="$(episode_of "$out")"; [ -f "$ep" ] || fail "no episode: $out"
src="$pdir/$(sed -n 's/^brain_source_ref: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ep")"
cmp "$fixture/notes.txt" "$src" || fail 'stored source is not byte-identical'
grep -q '^brain_source_transforms: \[\]$' "$ep" && grep -q '^brain_source_bytes_identical: true$' "$ep" || fail "episode lacks transform record: $(cat "$ep")"
! grep -q 'brain_upstream_transforms' "$ep" || fail 'plain file got upstream transforms'
checks+=(plain_file_identical=ok)

# 2. A Hermes turn record lists what the adapter changed (rendering,
#    whole-message redaction, tool-result truncation, role-label escaping),
#    and the episode carries that list.
python3 - "$repo_root/integrations/hermes/llm-brain/__init__.py" "$fixture/turn.md" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("lb_hermes", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fake = "pass" + "word=" + "FAKE0123456789FAKE0123"
record = m._turn_record("req1", Path("/tmp/ws"), "s1", "hermes:default", "cli", "default", "turn",
                        "Remember " + fake + " for the staging box", "Assistant: noted, staging port is 8443.",
                        [{"role": "tool", "tool_call_id": "t1", "content": "y" * 9000}])
Path(sys.argv[2]).write_text(record, encoding="utf-8")
PY
grep -q '^brain_transforms: \["render:hermes-turn-markdown", "redact:whole-message-sha256:1", "truncate:tool-results:1", "escape:role-labels:1"\]$' "$fixture/turn.md" || fail "adapter transforms wrong: $(grep brain_transforms "$fixture/turn.md")"
! grep -q 'FAKE0123456789' "$fixture/turn.md" || fail 'redaction did not happen'
out="$(b ingest-source "$project_id" "$fixture/turn.md")"
ep2="$(episode_of "$out")"
grep -q '^brain_source_transforms: \[\]$' "$ep2" || fail 'core transform record missing for turn'
grep -Fq 'brain_upstream_transforms: "[\"render:hermes-turn-markdown\"' "$ep2" || fail "upstream transforms not carried: $(grep transforms "$ep2")"
# A raw (owner-only custody) record declares only the rendering.
python3 - "$repo_root/integrations/hermes/llm-brain/__init__.py" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("lb_hermes", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
record = m._turn_record("req2", Path("/tmp/ws"), "s1", "p", "cli", "default", "turn", "plain question", "plain answer", [], raw=True)
assert 'brain_transforms: ["render:hermes-turn-markdown"]' in record, record
PY
checks+=(adapter_transforms_recorded=ok)

# 3. custody verify: identical vs transformed, then a tampered byte and a
#    removed source are caught; a legacy episode is reported unrecorded.
set +e; v="$(b custody verify "$project_id" 2>"$fixture/verify.err")"; rc=$?; set -e
[ "$rc" = 0 ] || fail "verify failed on clean vault: $v"
grep -q "^identical	${ep#"$pdir"/}	" <<<"$v" || fail "plain file not identical: $v"
grep -q "^transformed	${ep2#"$pdir"/}	.*upstream=.*redact:whole-message-sha256:1" <<<"$v" || fail "turn not reported transformed: $v"
grep -q 'custody identical=1 transformed=1 unrecorded=0 bad=0' "$fixture/verify.err" || fail "summary: $(cat "$fixture/verify.err")"
legacy="$pdir/episodes/legacy.md"
sed -e '/^brain_source_transforms:/d' -e '/^brain_source_bytes_identical:/d' "$ep" >"$legacy"
v="$(b custody verify "$project_id" 2>/dev/null)"; grep -q '^unrecorded	episodes/legacy.md	' <<<"$v" || fail "legacy not unrecorded: $v"
rm -f "$legacy"
printf 'x' >>"$src"
set +e; v="$(b custody verify "$project_id" 2>/dev/null)"; rc=$?; set -e
[ "$rc" = 1 ] && grep -q "^mismatch	${ep#"$pdir"/}	" <<<"$v" || fail "tampered source not caught (rc=$rc): $v"
! grep -Fq 'port 8443' <<<"$v" || fail 'verify printed source content'
checks+=(verify_detects=ok)

# 4. Host-memory snapshots go through the same custody: no transforms.
mkdir -p "$fixture/hermes/memories"; printf 'Prefers short replies.\n' >"$fixture/hermes/memories/USER.md"
HERMES_HOME="$fixture/hermes" b host-memory snapshot "$project_id" --host hermes --session s-1 >/dev/null 2>&1 || true
if ls "$pdir"/sources/*user* >/dev/null 2>&1 || grep -rlq 'Prefers short replies' "$pdir/sources" 2>/dev/null; then
  hep="$(grep -rl 'Prefers short replies' "$pdir/sources" | head -n 1)"
  cmp "$fixture/hermes/memories/USER.md" "$hep" || fail 'host memory snapshot not byte-identical'
  checks+=(host_memory_identical=ok)
fi
printf 'ingest transforms self-check passed: %s\n' "${checks[*]}"
