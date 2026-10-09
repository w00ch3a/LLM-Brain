#!/usr/bin/env bash
# Self-check for the stdio MCP server: protocol handshake, tool listing,
# read tools, review-only capture and the --read-only switch.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-mcp.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'mcp self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"
workspace="$fixture/workspace"
project_id="proj_mcp_self_check"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
{
  printf '%s\n' '---' 'type: Claim' 'title: MCP retry limit' 'status: stable'
  printf '%s\n' 'generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
  printf '%s\n' "brain_project_id: $project_id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_schema_version: 3'
  printf '%s\n' '---' '# MCP retry limit' '' 'The MCP fixture retry limit is 7 attempts.'
} >"$project_dir/okf/claims/mcp-retry.md"

cat >"$fixture/requests.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-check","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"brain_search","arguments":{"query":"retry limit"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"brain_pack_build","arguments":{"task":"retry limit"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"brain_recall","arguments":{"query":"retry limit"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"brain_status","arguments":{}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"brain_brief","arguments":{"max_bytes":512}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"brain_capture","arguments":{"title":"Decision","text":"We agreed the retry limit becomes 9."}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"brain_search","arguments":{"query":"x","paths":["../../etc/passwd"]}}}
{"jsonrpc":"2.0","id":10,"method":"ping"}
{"jsonrpc":"2.0","id":11,"method":"no/such"}
not json
JSONL
(cd "$workspace" && "$cli" --root "$vault" mcp serve <"$fixture/requests.jsonl" >"$fixture/responses.jsonl")
python3 - "$fixture/responses.jsonl" "$repo_root/VERSION" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
by_id = {row.get("id"): row for row in rows}
version = open(sys.argv[2], encoding="utf-8").read().strip()
assert len(rows) == 12, len(rows)  # notification gets no response
init = by_id[1]["result"]
assert init["protocolVersion"] == "2025-06-18"
assert init["serverInfo"] == {"name": "llm-brain", "version": version}
names = [tool["name"] for tool in by_id[2]["result"]["tools"]]
assert names == ["brain_search", "brain_pack_build", "brain_recall", "brain_status", "brain_brief", "brain_capture"], names
def text(i):
    result = by_id[i]["result"]
    assert result["isError"] is False, (i, result)
    return result["content"][0]["text"]
assert "okf/claims/mcp-retry.md" in text(3)
assert "MCP retry limit" in text(4) and "type: ContextPack" in text(4)
recall = json.loads(text(5))
assert recall["status"] == "ok" and "retry limit" in recall["context_markdown"].lower()
assert "maintenance=status" in text(6)
assert len(text(7).encode("utf-8")) <= 513 and "PROJECT BRIEF" in text(7)
capture = json.loads(text(8))
assert capture["status"] == "ok" and capture["review_ref"].startswith("review/")
assert by_id[9]["result"]["isError"] is True
assert by_id[10]["result"] == {}
assert by_id[11]["error"]["code"] == -32601
assert by_id[None]["error"]["code"] == -32700
PY
review_file="$(python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; print([json.loads(r["result"]["content"][0]["text"])["review_ref"] for r in rows if r.get("id") == 8][0])' "$fixture/responses.jsonl")"
grep -Fq 'brain_review_state: proposed' "$project_dir/$review_file" || fail 'capture was not review-only'
grep -Rqs 'retry limit becomes 9' "$project_dir/okf" && fail 'capture reached canonical memory'

# Read-only mode removes capture entirely.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"brain_capture","arguments":{"text":"x"}}}' |
  (cd "$workspace" && "$cli" --root "$vault" mcp serve --read-only) >"$fixture/readonly.jsonl"
python3 - "$fixture/readonly.jsonl" <<'PY'
import json, sys
rows = {row["id"]: row for row in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
assert "brain_capture" not in [tool["name"] for tool in rows[1]["result"]["tools"]]
assert rows[2]["error"]["code"] == -32602
PY

# Unknown working directories never invent a project.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"brain_search","arguments":{"query":"x"}}}' |
  (cd "$fixture" && "$cli" --root "$vault" mcp serve) >"$fixture/unknown.jsonl"
python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read()); assert r["result"]["isError"] is True' "$fixture/unknown.jsonl"
[ "$(find "$vault/projects" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ] || fail 'mcp created a project'

printf '%s\n' 'llm-brain mcp self-check passed'
