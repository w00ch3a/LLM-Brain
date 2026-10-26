#!/usr/bin/env bash
# Memthena NAS trust mode (MEMTHENA_NAS_TRUST_SECONDS / LLM_BRAIN_NAS_TRUST_SECONDS,
# opt-in, default 0 = off; bulk folder stat made it unnecessary): read-only search may skip the per-record lstat
# only while the change token (okf/ folders, folders of other cached records,
# the vault .locks/ folder, the audit log) is unchanged and the last full
# sweep is inside the window. Every write through the CLI (which Hermes and
# MCP use) invalidates at once; search output is identical either way.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-nas-trust.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_NAS_TRUST_SECONDS MEMTHENA_NAS_TRUST_SECONDS
fail() { printf 'nas-trust-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/v"; mkdir -p "$fixture/ws"; "$cli" --root "$vault" project ensure "$fixture/ws" --id proj_t >/dev/null
project="$vault/projects/proj_t"; mkdir -p "$project/okf/claims"
for i in 1 2 3 4 5 6; do
  printf -- '---\ntype: Claim\ntitle: Ferry %s\nbrain_review_state: approved\nbrain_sensitivity: internal\nbrain_schema_version: 3\n---\n# Ferry %s\n\nThe harbour ferry %s leaves at pier %s.\n' "$i" "$i" "$i" "$i" >"$project/okf/claims/c$i.md"
done
touch -d '-1 minute' "$project"/okf/claims/*.md 2>/dev/null || touch -t 202601010000 "$project"/okf/claims/*.md
search() { "$cli" --root "$vault" search proj_t "harbour ferry" --limit 10 "$@"; }
trusted() { python3 - "$repo_root" "$project" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib")); import okf
print("1" if okf.RecordCache(sys.argv[2], trust=True).trusted else "0")
PY
}
plain="$(LLM_BRAIN_NAS_TRUST_SECONDS=0 search)"
[ "$(LLM_BRAIN_NAS_TRUST_SECONDS=0 trusted)" = 0 ] || fail '=0 must disable trust'
# Default off (unset = 0): repeated searches never arm trust.
one="$(search)"; two="$(search)"
[ "$plain" = "$one" ] && [ "$one" = "$two" ] || fail 'default search output changed'
[ "$(trusted)" = 0 ] || fail 'default (unset) must not trust'
# Opt-in (30 s): one sweep, then trusted, same output.
export MEMTHENA_NAS_TRUST_SECONDS=30
one="$(search)"; two="$(search)"
[ "$plain" = "$one" ] && [ "$one" = "$two" ] || fail 'trust mode changed search output'
[ "$(trusted)" = 1 ] || fail 'opt-in 30 s must trust inside the window'
[ "$(LLM_BRAIN_NAS_TRUST_SECONDS=30 MEMTHENA_NAS_TRUST_SECONDS= trusted)" = 1 ] || fail 'LLM_BRAIN_ alias must opt in too'
[ "$(MEMTHENA_NAS_TRUST_SECONDS=0 trusted)" = 0 ] || fail 'MEMTHENA_NAS_TRUST_SECONDS=0 must disable trust'
[ "$(MEMTHENA_NAS_TRUST_SECONDS=junk trusted)" = 0 ] && [ "$(MEMTHENA_NAS_TRUST_SECONDS= LLM_BRAIN_NAS_TRUST_SECONDS=junk trusted)" = 0 ] || fail 'an invalid value must disable trust'
python3 - "$repo_root" <<'PY' || fail 'default must be 0 (off)'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib")); import okf
for k in ("MEMTHENA_NAS_TRUST_SECONDS", "LLM_BRAIN_NAS_TRUST_SECONDS"): os.environ.pop(k, None)
assert okf._trust_seconds() == 0
os.environ["MEMTHENA_NAS_TRUST_SECONDS"] = "5"; os.environ["LLM_BRAIN_NAS_TRUST_SECONDS"] = "99"; assert okf._trust_seconds() == 5
PY
# Every CLI write invalidates immediately (the next read-only run does a full sweep).
expect_invalidated() { # label command...
  search >/dev/null; [ "$(trusted)" = 1 ] || fail "not re-armed before: $1"
  local label="$1"; shift; "$@" >/dev/null 2>&1 || true
  [ "$(trusted)" = 0 ] || fail "write did not invalidate trust: $label"
}
mkrev() { printf -- '---\ntype: ReviewItem\ntitle: "%s"\nbrain_project_id: proj_t\nbrain_candidate_id: %s\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: internal\nbrain_loading_temperature: warm\nbrain_source_authority: user\nbrain_provider_id: fixture\nbrain_provider_version: "1"\nbrain_provenance: "episode://fixture"\nbrain_schema_version: 3\n---\n# %s\n\nThe harbour ferry %s has a new timetable.\n' "$1" "$1" "$1" "$1" >"$project/review/$1.md"; }
mkrev claim_trust01
expect_invalidated 'review decide (promote)' "$cli" --root "$vault" review decide proj_t claim_trust01 approved --actor human:test --reason fixture
search >/dev/null; [ -f "$project/okf/claims/claim_trust01.md" ] || fail 'promotion fixture failed'
after="$(search)"; grep -q 'claim_trust01' <<<"$after" || fail 'promoted record missing from search after write'
printf -- '---\ntitle: Hermes note\n---\nThe harbour ferry capture from Hermes.\n' >"$fixture/ws/note.md"
expect_invalidated 'bridge capture (Hermes path)' "$cli" --root "$vault" bridge capture --source-root "$fixture/ws" --project-id proj_t --record "$fixture/ws/note.md"
expect_invalidated 'ingest' "$cli" --root "$vault" --project-id proj_t ingest "$fixture/ws/note.md"
expect_invalidated 'index build' "$cli" --root "$vault" index build proj_t
# A record edited in place by a writer that does not use the CLI (hand edit) is
# only guaranteed to be seen after the window; with =0 it is seen at once.
search >/dev/null
python3 - "$project/okf/claims/c1.md" <<'PY'
import os, sys
p = sys.argv[1]; st = os.stat(p); t = open(p).read().replace("Ferry 1", "Ferry One")
open(p, "w").write(t)
PY
grep -q 'okf/claims/c1.md' <<<"$(MEMTHENA_NAS_TRUST_SECONDS= LLM_BRAIN_NAS_TRUST_SECONDS= search)" || fail 'default (off) must see the edit at once'
python3 - "$repo_root" "$project" <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib")); import okf
def fail(m): print("nas-trust-self-check:", m, file=sys.stderr); sys.exit(1)
project = sys.argv[2]
if okf.RecordCache(project).trusted: fail("only callers asking for trust may get it")
os.environ.pop("MEMTHENA_NAS_TRUST_SECONDS", None)
os.environ["LLM_BRAIN_NAS_TRUST_SECONDS"] = "1"
c = okf.RecordCache(project, trust=True); c.save()
time.sleep(1.2)
if okf.RecordCache(project, trust=True).trusted: fail("expired window must force a sweep")
print("nas-trust-self-check: ok")
PY
