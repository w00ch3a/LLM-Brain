#!/usr/bin/env bash
# Idea 8: pack build --action-risk low|medium|high (MEMTHENA_PACK_ACTION_RISK).
# Only high flags stale or single-source premises "re-verify before acting";
# unset/low/medium packs are byte-identical to the default.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-action-risk.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PACK_ACTION_RISK MEMTHENA_PACK_ACTION_RISK
fail() { printf 'pack-action-risk-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_action_risk"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims"
claim() { # id title stale_after sources body
  {
    printf '%s\n' '---' 'type: Claim' "title: $2" 'status: stable'
    printf '%s\n' 'generated: {by: process:test, at: 2026-08-07T00:00:00Z}' "sources: $4"
    [ -z "$3" ] || printf 'stale_after: %s\n' "$3"
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved'
    printf '%s\n' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal'
    printf '%s\n' 'brain_source_authority: repository' 'brain_provenance: human://fixture' 'brain_schema_version: 3'
    printf '%s\n' '---' "# $2" '' "$5"
  } >"$project/okf/claims/$1.md"
}
two='[{resource: source://alpha}, {resource: source://beta}]'
claim claim_stale1 'Ferry deploy gate stale' 2020-01-01 "$two" 'The ferry deploy gate needs two approvals.'
claim claim_single 'Ferry deploy gate single' '' '[{resource: source://alpha}]' 'The ferry deploy gate runs on Tuesdays.'
claim claim_sound1 'Ferry deploy gate sound' 2099-01-01 "$two" 'The ferry deploy gate is owned by ops.'
"$cli" --root "$vault" index build "$project_id" >/dev/null

build() { "$cli" --root "$vault" pack build "$project_id" --task 'ferry deploy gate' "$@" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
default_pack="$(build)"; [ -f "$default_pack" ] || fail 'default pack missing'
cp "$default_pack" "$fixture/default.md"
grep -q 'claim_stale1\|Ferry deploy gate stale' "$fixture/default.md" || fail 'fixture records not in pack'
! grep -qi 'action risk\|re-verify before acting' "$fixture/default.md" || fail 'default pack mentions action risk'

for level in low medium; do
  p="$(build --action-risk "$level")"
  [ "$p" = "$default_pack" ] || fail "$level pack path differs from default"
  cmp -s "$p" "$fixture/default.md" || fail "$level pack bytes differ from default"
done

high="$(build --action-risk high)"
[ "$high" != "$default_pack" ] || fail 'high pack reused default pack'
grep -Fxq 'brain_action_risk: high' "$high" || fail 'no brain_action_risk frontmatter'
grep -Fq '## Action Risk — high' "$high" || fail 'no action-risk header'
record_block() { awk -v t="$1" '/^### /{ on = (index($0, t) > 0) } on' "$high"; }
record_block 'Ferry deploy gate stale' | grep -Fq 'Action risk: <code>re-verify before acting</code> (stale)' || { cat "$high" >&2; fail 'stale premise not flagged'; }
record_block 'Ferry deploy gate single' | grep -Fq 'Action risk: <code>re-verify before acting</code> (single-source)' || fail 'single-source premise not flagged'
! record_block 'Ferry deploy gate sound' | grep -Fq 're-verify before acting' || fail 'sound premise flagged'
# The default pack is untouched by the high build.
cmp -s "$default_pack" "$fixture/default.md" || fail 'default pack rewritten'

# Env alias selects the same high pack.
alias_pack="$(MEMTHENA_PACK_ACTION_RISK=high build)"
[ "$alias_pack" = "$high" ] || fail 'MEMTHENA_PACK_ACTION_RISK alias ignored'
if "$cli" --root "$vault" pack build "$project_id" --task x --action-risk extreme >/dev/null 2>"$fixture/err"; then fail 'bad level accepted'; fi
grep -q '^memthena: ' "$fixture/err" || fail 'error lacks memthena: prefix'

# MCP brain_pack_build: optional action_risk maps to the same behaviour.
cat >"$fixture/mcp.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-check","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"brain_pack_build","arguments":{"project_id":"proj_action_risk","task":"ferry deploy gate"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"brain_pack_build","arguments":{"project_id":"proj_action_risk","task":"ferry deploy gate","action_risk":"medium"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"brain_pack_build","arguments":{"project_id":"proj_action_risk","task":"ferry deploy gate","action_risk":"high"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"brain_pack_build","arguments":{"project_id":"proj_action_risk","task":"ferry deploy gate","action_risk":"extreme"}}}
JSONL
(cd "$fixture/ws" && "$cli" --root "$vault" mcp serve <"$fixture/mcp.jsonl" >"$fixture/mcp.out")
python3 - "$fixture/mcp.out" <<'PY' || fail 'MCP action_risk check failed'
import json, re, sys
rows = {r.get("id"): r for r in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
tool = next(t for t in rows[2]["result"]["tools"] if t["name"] == "brain_pack_build")
prop = tool["inputSchema"]["properties"]["action_risk"]
assert prop["enum"] == ["low", "medium", "high"], prop
assert "action_risk" not in tool["inputSchema"].get("required", [])
text = lambda i: rows[i]["result"]["content"][0]["text"]
body = lambda i: re.sub(r"^.*?\n", "", text(i), count=1)  # drop the status line
assert not rows[3]["result"].get("isError") and "brain_action_risk" not in text(3)
assert "re-verify before acting" not in text(3)
assert body(4) == body(3), "medium MCP pack differs from default"
assert "brain_action_risk: high" in text(5) and "## Action Risk" in text(5)
assert "re-verify before acting" in text(5)
assert rows[6]["result"].get("isError") and "action_risk" in text(6), rows[6]
PY
"$cli" --root "$vault" lint --project "$project_id" >/dev/null || fail 'lint failed after high pack'
printf 'pack-action-risk-self-check: ok\n'
