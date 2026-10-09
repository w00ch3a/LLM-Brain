#!/usr/bin/env bash
# Two people, one host, two brains: each MCP server process is pinned to one
# brain root and can never read or write another.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-mcp-brains.XXXXXX")"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
fail() { printf 'mcp multi-brain self-check: %s\n' "$*" >&2; exit 1; }

make_brain() {
  local brain="$1" project_id="$2" marker="$3" workspace="$4"
  mkdir -p "$brain" "$workspace"; chmod 700 "$brain"
  "$cli" --root "$brain" project ensure "$workspace" --id "$project_id" >/dev/null
  {
    printf '%s\n' '---' 'type: Claim' "title: \"Holiday plan $marker\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_schema_version: 3'
    printf '%s\n' '---' "# Holiday plan $marker" '' "The holiday plan marker is $marker."
  } >"$brain/projects/$project_id/okf/claims/holiday.md"
}
make_brain "$fixture/alex-brain" proj_alex ALEXONLY "$fixture/alex-work"
make_brain "$fixture/sam-brain" proj_sam SAMONLY "$fixture/sam-work"

brain_digest() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256); }
sam_before="$(brain_digest "$fixture/sam-brain")"

serve() {  # serve BRAIN WORKDIR [extra...] < requests
  local brain="$1" workdir="$2"; shift 2
  (cd "$workdir" && LLM_BRAIN_ROOT="$fixture/sam-brain" "$cli" mcp serve --brain "$brain" "$@")
}
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }

{
  call 1 brain_search '{"query":"holiday plan"}'
  call 2 brain_search '{"query":"holiday plan","project_id":"proj_sam"}'
  call 3 brain_search '{"query":"holiday plan","root":"'"$fixture/sam-brain"'"}'
  call 4 brain_search '{"query":"holiday plan","brain":"'"$fixture/sam-brain"'"}'
  call 5 brain_search '{"query":"holiday plan","project_id":"../sam-brain/projects/proj_sam"}'
  call 6 brain_capture '{"text":"Alex private note CAPTUREALEX","project_id":"proj_alex"}'
  call 7 brain_brief '{"project_id":"proj_alex"}'
} | serve "$fixture/alex-brain" "$fixture/alex-work" >"$fixture/alex.jsonl"

python3 - "$fixture/alex.jsonl" <<'PY'
import json, sys
rows = {row["id"]: row for row in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
text = lambda i: rows[i]["result"]["content"][0]["text"]
# Even with LLM_BRAIN_ROOT pointing at Sam's brain, --brain pins Alex's.
assert rows[1]["result"]["isError"] is False and "Holiday plan ALEXONLY" in text(1), rows[1]
assert "SAMONLY" not in json.dumps(rows)
assert rows[2]["result"]["isError"] is True, rows[2]          # Sam's project is not in Alex's brain
assert rows[3]["error"]["code"] == -32602                     # cannot redirect the root
assert rows[4]["error"]["code"] == -32602
assert rows[5]["result"]["isError"] is True                   # traversal-shaped project id refused
assert rows[6]["result"]["isError"] is False, rows[6]
assert "ALEXONLY" in text(7)
PY
grep -Rqs CAPTUREALEX "$fixture/alex-brain/projects/proj_alex/sources" || fail 'capture missing from its own brain'
! grep -Rqs CAPTUREALEX "$fixture/sam-brain" || fail 'capture leaked into the other brain'
[ ! -d "$fixture/sam-brain/projects/proj_alex" ] || fail 'project leaked into the other brain'
[ "$sam_before" = "$(brain_digest "$fixture/sam-brain")" ] || fail 'other brain was modified'
[ -z "$(find "$fixture/alex-brain" -path '*.locks/*' -name 'project-*' -print -quit)" ] || fail 'stale lock left behind'

# Sam's server sees only Sam's brain.
call 1 brain_search '{"query":"holiday plan"}' | serve "$fixture/sam-brain" "$fixture/sam-work" >"$fixture/sam.jsonl"
grep -Fq SAMONLY "$fixture/sam.jsonl" || fail 'second brain not served'
! grep -Fq ALEXONLY "$fixture/sam.jsonl" || fail 'first brain leaked into second server'
! grep -Fq CAPTUREALEX "$fixture/sam.jsonl" || fail 'capture leaked into second server'

# A project pin narrows a server further.
call 1 brain_search '{"query":"holiday plan","project_id":"proj_other"}' | serve "$fixture/alex-brain" "$fixture/alex-work" --project-id proj_alex >"$fixture/pinned.jsonl"
grep -Fq 'pinned to a different project' "$fixture/pinned.jsonl" || fail 'project pin not enforced'

# Unsafe brain roots are refused before serving.
mkdir -p "$fixture/loose-brain"; chmod 777 "$fixture/loose-brain"
if printf '' | "$cli" mcp serve --brain "$fixture/loose-brain" >/dev/null 2>&1; then fail 'group/world-writable brain accepted'; fi
ln -s "$fixture/alex-brain" "$fixture/link-brain"
if printf '' | "$cli" mcp serve --brain "$fixture/link-brain" >/dev/null 2>&1; then fail 'symlinked brain accepted'; fi
if printf '' | "$cli" mcp serve --brain "$fixture/missing-brain" >/dev/null 2>&1; then fail 'missing brain accepted'; fi
python3 - "$repo_root/lib" "$fixture" <<'PY'
import os, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import mcp_server
if hasattr(os, "getuid") and os.getuid() == 0:
    raise SystemExit(0)  # root owns everything; ownership refusal is not observable
# A brain owned by another OS user is refused (simulated with a patched uid).
real = os.getuid
os.getuid = lambda: real() + 1
try:
    mcp_server.pin_brain(os.path.join(sys.argv[2], "alex-brain"))
except mcp_server.BrainError as error:
    assert "another OS user" in str(error)
else:
    raise SystemExit("foreign-owned brain accepted")
finally:
    os.getuid = real
PY

printf '%s\n' 'llm-brain mcp multi-brain self-check passed'
