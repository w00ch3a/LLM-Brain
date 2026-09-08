#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
hermes_root="${HERMES_SOURCE_ROOT:-$HOME/.hermes/hermes-agent}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
workspace="$fixture/workspace"
hermes_home="$fixture/hermes"
mkdir -p "$workspace" "$hermes_home"
project_id="proj_hermes_self_check"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null

cat >"$vault/projects/$project_id/okf/claims/bridge.md" <<'EOF'
---
type: Claim
title: Hermes bridge contract
status: stable
generated: {by: "human:test", at: "2026-08-08T00:00:00Z"}
sources: [{resource: "self-check fixture"}]
brain_project_id: proj_hermes_self_check
brain_review_state: approved
brain_source_authority: human-directive
brain_sensitivity: internal
brain_loading_temperature: hot
brain_schema_version: 3
---
# Hermes bridge contract

The Hermes bridge preserves provenance and survives concurrent requests.
EOF

printf '%s\n' 'Hermes bridge contract' >"$fixture/query.txt"
cat >"$fixture/one.md" <<'EOF'
---
type: HermesTurn
brain_request_id: hermes_fixture_request
---
# First structured turn
EOF
printf '%s\n' 'second structured turn' >"$fixture/two.md"

capture_one="$("$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/one.md")"
capture_two="$("$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/one.md")"
printf '%s\n' "$capture_one" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["status"] == "ok"; assert p["request_id"] == "hermes_fixture_request"; assert p["episode_ref"].startswith("episodes/"); assert p["review_ref"].startswith("review/"); assert p["deduplication_ref"] == "sha256:" + p["source_hash"]'
printf '%s\n' "$capture_two" | python3 -c 'import json,sys; assert json.load(sys.stdin)["idempotent"] is True'

"$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/two.md" >/dev/null & one_pid=$!
"$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/one.md" >/dev/null & two_pid=$!
wait "$one_pid"
wait "$two_pid"
! grep -R -F 'lock held' "$fixture" >/dev/null 2>&1
episode_count="$(find "$vault/projects/$project_id/episodes" -type f -name '*.md' | wc -l | tr -d ' ')"
[ "$episode_count" -ge 2 ]

recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --strategy lexical --require-evidence)"
printf '%s\n' "$recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); c=p["context_markdown"]; assert p["status"] == "ok"; assert p["results"]; assert "okf/claims/bridge.md" in p["evidence_refs"]; assert p["actual_strategy"].startswith("lexical"); assert "Hermes bridge contract" in c; assert len(c.encode("utf-8")) <= 16000; assert c.endswith(".\n")'
tiny_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --strategy lexical --budget-tokens 1)"
printf '%s\n' "$tiny_recall" | python3 -c 'import json,sys; assert len(json.load(sys.stdin)["context_markdown"].encode("utf-8")) <= 4'

cat >"$fixture/embedder.sh" <<'EMBEDDER'
#!/usr/bin/env bash
if grep -Fqi 'residence changed' "$1" || grep -Fqi 'relocated to Melbourne' "$1"; then vector='1 0'; else vector='0 1'; fi
printf 'model: fixture-evidence\ndimensions: 2\nvector: %s\n' "$vector"
EMBEDDER
chmod 755 "$fixture/embedder.sh"
cat >"$fixture/evidence.md" <<'EOF'
---
type: HermesTurn
title: "Residence update"
brain_request_id: hermes_evidence_request
brain_principal: "hermes:test"
brain_observed_at: "2026-08-08T12:00:00Z"
---
# Residence update

The user relocated to Melbourne.
EOF
LLM_BRAIN_EMBEDDER="$fixture/embedder.sh" LLM_BRAIN_EMBEDDER_VERSION=fixture "$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/evidence.md" >/dev/null
printf '%s\n' 'Did the residence change?' >"$fixture/evidence-query.txt"
evidence_recall="$(LLM_BRAIN_QUERY_EMBEDDER="$fixture/embedder.sh" "$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/evidence-query.txt" --principal hermes:test --strategy hybrid)"
printf '%s\n' "$evidence_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert "hybrid-evidence-rrf" in p["actual_strategy"]; assert p["degraded"] is False; assert "relocated to Melbourne" in p["context_markdown"]; assert "2026-08-08T12:00:00Z" in p["context_markdown"]'
printf '%s\n' "$evidence_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); rows=[r for r in p["results"] if r["type"] == "HermesTurn"]; assert rows and all(r["principal"] == "hermes:test" for r in rows); assert all(r["source_hash"] and r["excerpt"] and r["observed_at"] for r in rows)'
project="$vault/projects/$project_id"
run_loaded_index_check() {
  local evidence_index="$project/indexes/evidence-vectors.tsv"
  local evidence_source="$project/$(sed -n '2s/\t.*//p' "$evidence_index")"
  for number in $(seq 1 220); do
    rel="sources/evidence-load-$number.md"
    cp "$evidence_source" "$project/$rel"
    awk -F '\t' -v OFS='\t' -v rel="$rel" 'NR == 2 { $1=rel; print; exit }' "$evidence_index" >>"$evidence_index"
  done
  loaded_recall="$(LLM_BRAIN_QUERY_EMBEDDER="$fixture/embedder.sh" "$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/evidence-query.txt" --principal hermes:test --strategy hybrid)"
  printf '%s\n' "$loaded_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["results"]; assert p["status"] == "ok"'
}

make_evidence_fixture() {
  local file="$1" title="$2" request_id="$3" observed="$4" user_content="$5" assistant_content="$6"
  {
    printf '%s\n' '---'
    printf 'type: HermesTurn\ntitle: "%s"\nbrain_request_id: %s\nbrain_principal: "hermes:test"\nbrain_observed_at: "%s"\n' "$title" "$request_id" "$observed"
    printf '%s\n' '---' "# $title" '' '## User content' '' "$user_content" '' '## Assistant content' '' "$assistant_content"
  } >"$file"
}

make_evidence_fixture "$fixture/user-basketball.md" "User basketball preference" hermes_user_basketball 2026-08-09T00:00:00Z 'I prefer casual basketball pickup games in summer to keep cardio fun.' 'Jackson prefers basketball in summer too.'
make_evidence_fixture "$fixture/jackson-basketball.md" "Jackson basketball preference" hermes_jackson_basketball 2026-08-10T00:00:00Z 'Jackson enjoys basketball in summer.' 'The user prefers basketball every weekend.'
make_evidence_fixture "$fixture/old-company.md" "Old company" hermes_old_company 2026-08-01T00:00:00Z 'My company was Future Intelligence in the media industry.' 'The company history is recorded.'
make_evidence_fixture "$fixture/new-company.md" "New company" hermes_new_company 2026-08-11T00:00:00Z 'My company is Northern Logistics in the legal industry.' 'The user changed company.'
make_evidence_fixture "$fixture/new-company-repeat-1.md" "New company repeat 1" hermes_new_company_repeat_1 2026-08-12T00:00:00Z 'I continue working at Northern Logistics in the legal industry.' 'The same employer is repeated.'
make_evidence_fixture "$fixture/new-company-repeat-2.md" "New company repeat 2" hermes_new_company_repeat_2 2026-08-13T00:00:00Z 'Northern Logistics remains my employer in the legal sector.' 'The same employer is repeated again.'
make_evidence_fixture "$fixture/new-company-repeat-3.md" "New company repeat 3" hermes_new_company_repeat_3 2026-08-14T00:00:00Z 'My current job is still at Northern Logistics.' 'The same employer is repeated once more.'
make_evidence_fixture "$fixture/old-birthdate.md" "Old birthdate" hermes_old_birthdate 2026-08-02T00:00:00Z 'My birthdate is 1988-05-14.' 'The birthdate is fixed.'
make_evidence_fixture "$fixture/new-birthdate.md" "New birthdate conflict" hermes_new_birthdate 2026-08-12T00:00:00Z 'My birthdate is 1990-05-14.' 'The birthdate is 1990-05-14.'
make_evidence_fixture "$fixture/user-audiobook.md" "User audiobook condition" hermes_user_audiobook 2026-08-13T00:00:00Z 'I prefer audiobooks for professional self-improvement while commuting.' 'Jackson prefers audiobooks at bedtime.'
make_evidence_fixture "$fixture/old-marital.md" "Old marital status" hermes_old_marital 2026-08-03T00:00:00Z 'I was married.' 'The earlier marital status is recorded.'
make_evidence_fixture "$fixture/new-marital.md" "New marital status" hermes_new_marital 2026-08-15T00:00:00Z 'I am divorced.' 'The later marital status is recorded.'
make_evidence_fixture "$fixture/old-children.md" "Old children status" hermes_old_children 2026-08-04T00:00:00Z 'I did not have children.' 'The earlier children status is recorded.'
make_evidence_fixture "$fixture/new-children.md" "New children status" hermes_new_children 2026-08-16T00:00:00Z 'I have two children.' 'The later children status is recorded.'
make_evidence_fixture "$fixture/old-employment-status.md" "Earlier employment status" hermes_old_employment 2026-08-05T00:00:00Z 'I was employed.' 'The earlier employment status is recorded.'
make_evidence_fixture "$fixture/new-employment-status.md" "Later employment status" hermes_new_employment 2026-08-17T00:00:00Z 'I am employed.' 'The later employment status is recorded.'
make_evidence_fixture "$fixture/user-sibling.md" "User sibling count" hermes_user_sibling 2026-08-06T00:00:00Z 'I have one sibling, my sister Sophie.' 'The user sibling count is recorded.'
make_evidence_fixture "$fixture/friend-sibling.md" "Friend sibling count" hermes_friend_sibling 2026-08-07T00:00:00Z 'My friend Liam has two siblings.' 'The unrelated family reference is recorded.'
for evidence_fixture in "$fixture/user-basketball.md" "$fixture/jackson-basketball.md" "$fixture/old-company.md" "$fixture/new-company.md" "$fixture/old-birthdate.md" "$fixture/new-birthdate.md" "$fixture/user-audiobook.md" "$fixture/old-marital.md" "$fixture/new-marital.md" "$fixture/old-children.md" "$fixture/new-children.md" "$fixture/old-employment-status.md" "$fixture/new-employment-status.md" "$fixture/user-sibling.md" "$fixture/friend-sibling.md"; do
  LLM_BRAIN_EMBEDDER="$fixture/embedder.sh" LLM_BRAIN_EMBEDDER_VERSION=fixture "$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$evidence_fixture" >/dev/null
done

printf '%s\n' 'When does the user prefer basketball?' >"$fixture/basketball-query.txt"
basketball_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/basketball-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$basketball_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); rows=[r for r in p["results"] if r["type"] == "HermesTurn"]; c=p["context_markdown"]; assert rows and rows[0]["title"] == "User basketball preference"; assert "correct subject and condition" in c and "summer" in c and "User basketball preference" in c'

printf '%s\n' 'What changed about my company?' >"$fixture/company-query.txt"
company_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/company-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$company_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"] if r["type"] == "HermesTurn"]; assert "Old company" in titles[:3] and "New company" in titles[:3]; assert p["resolution_mode"] == "dynamic"; assert "earlier and later evidence" in p["context_markdown"]'
printf '%s\n' 'Which company did I switch from and to?' >"$fixture/company-switch-query.txt"
company_switch_recall="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/company-switch-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$company_switch_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["resolution_mode"] == "dynamic"; assert "Old company" in [r["title"] for r in p["results"][:3]]; assert "New company" in [r["title"] for r in p["results"][:3]]'
printf '%s\n' 'Did my employment status stay the same?' >"$fixture/employment-stayed-query.txt"
employment_stayed_recall="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/employment-stayed-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$employment_stayed_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"][:3]]; assert p["resolution_mode"] == "dynamic"; assert "Earlier employment status" in titles and "Later employment status" in titles; assert "earlier and later evidence" in p["context_markdown"]'
printf '%s\n' "Did the user's marital status change?" >"$fixture/marital-query.txt"
marital_recall="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/marital-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$marital_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"][:3]]; c=p["context_markdown"]; assert p["resolution_mode"] == "dynamic"; assert "Old marital status" in titles and "New marital status" in titles; assert c.index("Old marital status") < c.index("New marital status")'
printf '%s\n' "Has the user's children status changed recently?" >"$fixture/children-query.txt"
children_recall="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/children-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$children_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"][:3]]; c=p["context_markdown"]; assert p["resolution_mode"] == "dynamic"; assert "Old children status" in titles and "New children status" in titles; assert c.index("Old children status") < c.index("New children status")'
printf '%s\n' 'How many siblings does the user have?' >"$fixture/sibling-query.txt"
sibling_recall="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/sibling-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$sibling_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"][:3]]; assert p["resolution_mode"] == "static"; assert "User sibling count" in titles; assert "Friend sibling count" not in titles[:1]'
for evidence_fixture in "$fixture/new-company-repeat-1.md" "$fixture/new-company-repeat-2.md" "$fixture/new-company-repeat-3.md"; do
  LLM_BRAIN_EMBEDDER="$fixture/embedder.sh" LLM_BRAIN_EMBEDDER_VERSION=fixture "$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$evidence_fixture" >/dev/null
done
company_repeat_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/company-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$company_repeat_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"] if r["type"] == "HermesTurn"]; assert "Old company" in titles[:5]'
printf '%s\n' "$company_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"] if r["type"] == "HermesTurn"]; assert "Old company" in titles[:5]; assert sum("New company" in title for title in titles[:5]) < 5'

printf '%s\n' 'What is my birthdate?' >"$fixture/birthdate-query.txt"
birthdate_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/birthdate-query.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$birthdate_recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); titles=[r["title"] for r in p["results"] if r["type"] == "HermesTurn"]; c=p["context_markdown"]; assert "Old birthdate" in titles[:3] and "New birthdate conflict" in titles[:3]; assert "Answer mode: `static`" in c and "STATIC CLAIMS ARE NOT CANONICAL" in c and "sources disagree" in c and "relation birthdate" in c'

legacy_index="$project/indexes/evidence-vectors.tsv"
printf '%s\n' 'path\thash\tmodel\tdimensions\tprincipal\tobserved_at\ttitle\tvector' >"$legacy_index"
make_evidence_fixture "$fixture/rebuild-trigger.md" "Rebuild trigger" hermes_rebuild_trigger 2026-08-14T00:00:00Z 'My company is still Northern Logistics.' 'The index must rebuild from custody.'
LLM_BRAIN_EMBEDDER="$fixture/embedder.sh" LLM_BRAIN_EMBEDDER_VERSION=fixture "$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$fixture/rebuild-trigger.md" >/dev/null
expected_evidence_header="$(printf 'path\thash\tview_version\tview_hash\tview_path\tmodel\tdimensions\tprincipal\tobserved_at\ttitle\tvector\tclaims_version')"
printf '%s\n' "$(head -1 "$legacy_index")" | grep -Fqx -- "$expected_evidence_header" || { printf 'stale evidence index was not rebuilt\n' >&2; exit 1; }
claims_projection="$(find "$project/indexes/evidence-claims" -maxdepth 1 -type f -name '*-claims-v2.txt' -print -quit)"
[ -n "$claims_projection" ] && grep -Fqx -- 'derived=claim-projection-v2' "$claims_projection"

if [ ! -d "$hermes_root" ]; then
  run_loaded_index_check
  printf 'Hermes source unavailable; bridge checks passed, provider checks skipped\n'
  exit 0
fi

PYTHONPATH="$hermes_root" TERMINAL_CWD="$workspace" HERMES_HOME="$hermes_home" python3 - "$repo_root" "$vault" "$workspace" "$hermes_home" <<'PY'
import copy
import importlib.util
import json
import sys
import time
import types
from pathlib import Path

repo_root, vault, workspace, hermes_home = map(Path, sys.argv[1:])
from agent.context_engine import ContextEngine

class FakeCompressor(ContextEngine):
    def __init__(self, model=""):
        self.model = model
        self.threshold_percent = 0.5
        self.protect_first_n = 3
        self.protect_last_n = 20
        self.context_length = 1000
        self.threshold_tokens = 500
        self.last_prompt_tokens = 0
        self.last_completion_tokens = 0
        self.last_total_tokens = 0
        self.compression_count = 0
    def update_from_response(self, usage):
        self.last_prompt_tokens = usage.get("prompt_tokens", 0)
        self.last_completion_tokens = usage.get("completion_tokens", 0)
        self.last_total_tokens = usage.get("total_tokens", 0)
    def should_compress(self, prompt_tokens=None):
        return False
    def compress(self, messages, current_tokens=None, focus_topic=None, force=False, memory_context=""):
        return list(messages)
    def on_session_reset(self):
        self.last_prompt_tokens = self.last_completion_tokens = self.last_total_tokens = 0

fake = types.ModuleType("agent.context_compressor")
fake.ContextCompressor = FakeCompressor
sys.modules["agent.context_compressor"] = fake
module_path = repo_root / "integrations/hermes/llm-brain/__init__.py"
spec = importlib.util.spec_from_file_location("llm_brain_hermes_self_check", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cli = str(repo_root / "bin/llm-brain")
module.LLMBrainMemoryProvider().save_config({
    "vault_root": str(vault), "cli_path": cli, "project_id": "proj_hermes_self_check",
    "strategy": "lexical", "recall_budget_tokens": 4000, "timeout_seconds": 6,
    "unsupported_setting": "must-not-persist",
}, str(hermes_home))
saved_config = __import__("json").loads((hermes_home / "llm-brain.json").read_text(encoding="utf-8"))
assert set(saved_config) == module.CONFIG_KEYS
default_config = module._load_config(None)
assert set(default_config) == module.CONFIG_KEYS
assert default_config["strategy"] == "hybrid"
config_path = hermes_home / "llm-brain.json"
config_before = config_path.read_bytes()
assert module._load_config(hermes_home) == saved_config
assert config_path.read_bytes() == config_before
assert module._workspace(hermes_home, "hermes") == (hermes_home / "workspace/hermes").resolve()

# Partial writes must preserve the other five public configuration keys in the
# selected Hermes profile rather than reintroducing process defaults.
partial_home = hermes_home.parent / "hermes-partial-config"
partial_provider = module.LLMBrainMemoryProvider()
partial_provider.save_config({
    "vault_root": str(vault / "partial-vault"), "cli_path": cli, "project_id": "proj_partial",
    "strategy": "lexical", "recall_budget_tokens": 777, "timeout_seconds": 11,
}, str(partial_home))
partial_provider.save_config({"timeout_seconds": 19}, str(partial_home))
partial_saved = json.loads((partial_home / "llm-brain.json").read_text(encoding="utf-8"))
assert partial_saved == {
    "vault_root": str(vault / "partial-vault"), "cli_path": cli, "project_id": "proj_partial",
    "strategy": "lexical", "recall_budget_tokens": 777, "timeout_seconds": 19,
}

restricted = module._tool_evidence([{
    "role": "tool", "tool_call_id": "restricted",
    "status": "token=leaked-status",
    "content": "api_key=secret-secret-secret /tmp/token=leaked-path",
}])
assert "leaked-path" not in restricted and "leaked-status" not in restricted
assert "sha256" in restricted and "restricted or omitted" in restricted
unicode_evidence = module._tool_evidence([{
    "role": "tool", "tool_call_id": "unicode", "content": "😀" * 10000,
}])
unicode_excerpt = unicode_evidence.split("excerpt: ", 1)[1]
assert len(unicode_excerpt.encode("utf-8")) <= module.MAX_TOOL_EXCERPT_BYTES
many_evidence = module._tool_evidence([
    {"role": "tool", "tool_call_id": str(index), "content": "😀" * 10000}
    for index in range(10)
])
excerpt_bytes = sum(
    len(line.split("excerpt: ", 1)[1].encode("utf-8"))
    for line in many_evidence.splitlines() if "excerpt: " in line and "[restricted" not in line
)
assert excerpt_bytes <= module.MAX_TURN_EXCERPT_BYTES
lineage_record = module._turn_record(
    "a" * 24, workspace, "session", "principal", "cli", "agent", "delegation",
    "task", "result", [], {"evidence_path": Path("/tmp/evidence")},
)
assert '"evidence_path": "/tmp/evidence"' in lineage_record

malformed_cli = hermes_home / "malformed-bridge"
malformed_cli.write_text("#!/usr/bin/env python3\nprint('not-json')\n", encoding="utf-8")
malformed_cli.chmod(0o700)
assert module._bridge_call({**saved_config, "cli_path": str(malformed_cli)}, workspace, ["recall"]) is None
legacy_cli = hermes_home / "legacy-bridge"
legacy_cli.write_text(
    "#!/usr/bin/env python3\n"
    "import json\n"
    "print(json.dumps({'context_markdown': '😀' * 100, 'results': [], 'legacy_field': 'kept'}))\n",
    encoding="utf-8",
)
legacy_cli.chmod(0o700)
legacy_payload = module._bridge_call(
    {**saved_config, "cli_path": str(legacy_cli)}, workspace,
    ["recall", "--budget-tokens", "2"],
)
assert legacy_payload and legacy_payload["status"] == "ok"
assert legacy_payload["legacy_field"] == "kept"
assert len(legacy_payload["context_markdown"].encode("utf-8")) <= 8
assert legacy_payload["context_markdown"].encode("utf-8").decode("utf-8") == legacy_payload["context_markdown"]
failed_cli = hermes_home / "failed-bridge"
failed_cli.write_text(
    "#!/usr/bin/env python3\nprint('{\"status\": \"failed\", \"error\": \"fixture failure\"}')\n",
    encoding="utf-8",
)
failed_cli.chmod(0o700)
failed_config = {**saved_config, "cli_path": str(failed_cli)}
failed_payload = module._bridge_call(failed_config, workspace, ["recall"])
assert failed_payload and failed_payload["status"] == "failed"
assert module._recall(failed_config, hermes_home, workspace, "self-check-user", "fixture") is None
malformed_payload_cli = hermes_home / "malformed-payload-bridge"
malformed_payload_cli.write_text(
    "#!/usr/bin/env python3\nprint('{\"status\": \"ok\", \"context_markdown\": []}')\n",
    encoding="utf-8",
)
malformed_payload_cli.chmod(0o700)
assert module._bridge_call(
    {**saved_config, "cli_path": str(malformed_payload_cli)}, workspace, ["recall"]
) is None
malformed_legacy_payload_cli = hermes_home / "malformed-legacy-payload-bridge"
malformed_legacy_payload_cli.write_text(
    "#!/usr/bin/env python3\nprint('{\"context\": [], \"results\": []}')\n",
    encoding="utf-8",
)
malformed_legacy_payload_cli.chmod(0o700)
assert module._bridge_call(
    {**saved_config, "cli_path": str(malformed_legacy_payload_cli)}, workspace, ["recall"]
) is None
assert module._normalise_bridge_payload(
    {"status": "ok", "context_markdown": "valid", "context": {"unexpected": "shape"}, "results": []},
    kind="recall",
) is None

# Bridge additions remain available but are bounded independently of the
# context Markdown budget, result/evidence list length, and tool response cap.
oversized_bridge_payload = {
    "status": "ok",
    "context_markdown": "😀" * 100000,
    "results": [{"title": "result", "excerpt": "r" * 100000} for _ in range(100)],
    "evidence_bundles": [{"source_hash": "h" * 100000, "claims": ["c" * 10000]} for _ in range(100)],
    "evidence_refs": ["ref-" + ("x" * 1000) for _ in range(100)],
    "legacy_field": "legacy-" + ("l" * 100000),
    "legacy_nested": {"items": ["n" * 100000 for _ in range(100)]},
}
bounded_bridge_payload = module._normalise_bridge_payload(
    oversized_bridge_payload, kind="recall", budget_tokens=10**9,
)
assert bounded_bridge_payload and bounded_bridge_payload["status"] == "ok"
assert len(json.dumps(bounded_bridge_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) <= module.MAX_TOOL_RESPONSE_BYTES
assert len(bounded_bridge_payload["context_markdown"].encode("utf-8")) <= module.MAX_CONTEXT_BYTES
assert len(bounded_bridge_payload["results"]) <= module.MAX_RESULT_ITEMS
assert len(bounded_bridge_payload["evidence_bundles"]) <= module.MAX_EVIDENCE_BUNDLE_ITEMS
assert len(bounded_bridge_payload["evidence_refs"]) <= module.MAX_EVIDENCE_REF_ITEMS
assert len(bounded_bridge_payload["legacy_field"].encode("utf-8")) <= module.MAX_ADDITIVE_FIELD_BYTES
assert bounded_bridge_payload["truncation"]["adapter_truncated"] is True
assert "legacy_field" in bounded_bridge_payload
assert module._normalise_bridge_payload(
    {"status": "ok", "failed": True, "context_markdown": "must not inject", "results": []},
    kind="recall",
) is None
slow_cli = hermes_home / "slow-bridge"
slow_cli.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(5)\n", encoding="utf-8")
slow_cli.chmod(0o700)
started = time.monotonic()
assert module._bridge_call({**saved_config, "cli_path": str(slow_cli), "timeout_seconds": 1}, workspace, ["recall"]) is None
assert time.monotonic() - started < 2.0

provider = module.LLMBrainMemoryProvider()
provider.initialize("session-1", hermes_home=str(hermes_home), agent_workspace=str(workspace), platform="cli", agent_identity="self-check", user_id="self-check-user", agent_context="primary")
schema = provider.get_tool_schemas()[0]
assert schema["name"] == "llm_brain_search"
assert "intent" in schema["parameters"]["properties"] and "current_state" in schema["parameters"]["properties"]["intent"]["enum"]
captured_bridge_args = []
real_bridge_call = module._bridge_call
module._bridge_call = lambda config, source, args: captured_bridge_args.append(list(args)) or {"status": "ok", "context_markdown": "state context", "results": []}
tool_result = provider.handle_tool_call("llm_brain_search", {"query": "state query", "intent": "current_state"})
assert "state context" in tool_result
assert "--intent" in captured_bridge_args[0] and captured_bridge_args[0][captured_bridge_args[0].index("--intent") + 1] == "current_state"
captured_bridge_args.clear()
provider.handle_tool_call("llm_brain_search", {"query": "factual query"})
assert "--intent" in captured_bridge_args[0] and captured_bridge_args[0][captured_bridge_args[0].index("--intent") + 1] == "factual"
module._bridge_call = real_bridge_call

# The tool surface applies the same cap even when a bridge implementation
# returns an oversized additive payload directly.
real_recall = module._recall
module._recall = lambda *args, **kwargs: oversized_bridge_payload
tool_payload = json.loads(provider.handle_tool_call("llm_brain_search", {"query": "bounded"}))
module._recall = real_recall
assert len(json.dumps(tool_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) <= module.MAX_TOOL_RESPONSE_BYTES
assert tool_payload["status"] == "ok" and tool_payload["legacy_field"]
assert len(tool_payload["results"]) <= module.MAX_RESULT_ITEMS
assert len(tool_payload["evidence_bundles"]) <= module.MAX_EVIDENCE_BUNDLE_ITEMS
# Selecting the context engine makes it the sole recall injector; durable
# capture remains owned by the provider.
config_pkg = types.ModuleType("hermes_cli")
config_mod = types.ModuleType("hermes_cli.config")
config_mod.load_config = lambda: {"context": {"engine": "llm-brain"}}
config_pkg.config = config_mod
sys.modules["hermes_cli"] = config_pkg
sys.modules["hermes_cli.config"] = config_mod
assert provider.prefetch("Hermes bridge contract") == ""
started = time.monotonic()
provider.sync_turn("Remember the bridge.", "Stored with provenance.", session_id="session-1", messages=[
    {"role": "user", "content": "Remember the bridge."},
    {"role": "assistant", "content": "Stored with provenance."},
])
assert time.monotonic() - started < 1.0
provider.shutdown()
committed = list((hermes_home / "llm-brain/outbox/committed").glob("*.md"))
assert committed, list((hermes_home / "llm-brain/outbox").glob("*"))
episodes_after_first_turn = len(list((vault / "projects/proj_hermes_self_check/episodes").rglob("*.md")))
provider.sync_turn("Remember the bridge.", "Stored with provenance.", session_id="session-1", messages=[
    {"role": "user", "content": "Remember the bridge."},
    {"role": "assistant", "content": "Stored with provenance."},
])
provider.shutdown()
assert len(list((vault / "projects/proj_hermes_self_check/episodes").rglob("*.md"))) == episodes_after_first_turn

provider.sync_turn("token=do-not-store", "Bearer do-not-store", session_id="session-1", messages=[
    {"role": "user", "content": "token=do-not-store"},
    {"role": "assistant", "content": "Bearer do-not-store"},
    {"role": "tool", "tool_call_id": "t1", "content": "api_key=do-not-store"},
])
provider.shutdown()
assert all("do-not-store" not in path.read_text(encoding="utf-8") for path in (hermes_home / "llm-brain/outbox/committed").glob("*.md"))

# A worker crash can leave ownership at ``running``. A later provider must
# reclaim it without a human queue or a lock bypass.
stale_id = module._sha("stale-hermes-turn")[:24]
stale_running = hermes_home / "llm-brain/outbox/running"
stale_running.mkdir(parents=True, exist_ok=True)
stale_path = stale_running / f"999999-1-{stale_id}.md"
stale_record = module._turn_record(
    stale_id, workspace, "session-1", "self-check-user", "cli", "self-check",
    "turn", "stale user", "stale assistant", [],
).replace("brain_processing_state: pending", "brain_processing_state: running\nbrain_attempts: 1")
module._atomic_write(stale_path, stale_record)
recovering = module.LLMBrainMemoryProvider()
recovering.initialize("session-1", hermes_home=str(hermes_home), agent_workspace=str(workspace), platform="cli", agent_identity="self-check", user_id="self-check-user", agent_context="primary")
recovering.shutdown()
assert (hermes_home / "llm-brain/outbox/committed" / f"{stale_id}.md").exists()
assert not any("stale assistant" in path.read_text(encoding="utf-8") for path in (vault / "projects/proj_hermes_self_check/okf").rglob("*.md"))

# Two provider instances may see the same pending record. Core idempotency and
# atomic outbox moves must converge without a duplicate episode or stranded file.
race_id = module._sha("concurrent-hermes-turn")[:24]
race_path = hermes_home / "llm-brain/outbox" / f"{race_id}.md"
module._atomic_write(race_path, module._turn_record(
    race_id, workspace, "session-1", "self-check-user", "cli", "self-check",
    "turn", "concurrent user", "concurrent assistant", [],
))
episodes_before = len(list((vault / "projects/proj_hermes_self_check/episodes").rglob("*.md")))
race_one = module.LLMBrainMemoryProvider()
race_two = module.LLMBrainMemoryProvider()
for item in (race_one, race_two):
    item.initialize("session-1", hermes_home=str(hermes_home), agent_workspace=str(workspace), platform="cli", agent_identity="self-check", user_id="self-check-user", agent_context="primary")
    item._start_drain()
race_one.shutdown()
race_two.shutdown()
assert (hermes_home / "llm-brain/outbox/committed" / race_path.name).exists()
assert not race_path.exists()
episodes_after = len(list((vault / "projects/proj_hermes_self_check/episodes").rglob("*.md")))
assert episodes_after == episodes_before + 1, (episodes_before, episodes_after)

# Hermes profiles keep their outboxes isolated even when they share a vault.
profile_two_home = hermes_home.parent / "hermes-two"
profile_two = module.LLMBrainMemoryProvider()
profile_two.save_config({
    "vault_root": str(vault), "cli_path": cli, "project_id": "proj_hermes_self_check",
    "strategy": "lexical", "recall_budget_tokens": 4000, "timeout_seconds": 6,
}, str(profile_two_home))
profile_two.initialize("session-two", hermes_home=str(profile_two_home), agent_workspace=str(workspace), platform="cli", agent_identity="second", user_id="second-user", agent_context="primary")
profile_two.sync_turn("second profile", "isolated record", session_id="session-two")
profile_two.shutdown()
assert list((profile_two_home / "llm-brain/outbox/committed").glob("*.md"))
assert not any("isolated record" in path.read_text(encoding="utf-8") for path in (hermes_home / "llm-brain/outbox/committed").glob("*.md"))

class MemoryCollector:
    def __init__(self): self.provider = None; self.providers = []
    def register_memory_provider(self, provider): self.provider = provider; self.providers.append(provider)
class ContextCollector:
    def __init__(self): self.engine = None; self.engines = []
    def register_context_engine(self, engine): self.engine = engine; self.engines.append(engine)
memory_collector = MemoryCollector()
context_collector = ContextCollector()
module.register(memory_collector)
module.register(context_collector)
module.register(memory_collector)
module.register(context_collector)
assert memory_collector.provider.name == "llm-brain"
assert len(memory_collector.providers) == 1
assert context_collector.engine.name == "llm-brain"
assert len(context_collector.engines) == 1
assert isinstance(context_collector.engine, ContextEngine)

# Fresh slot-based wrappers cannot carry adapter attributes.  Use only the
# public profile/lifecycle surface to deduplicate them, and release claims on
# unload so a later profile reload is not suppressed or cross-profile leaked.
class SlotCollector:
    __slots__ = ("profile_name", "providers", "engines", "callbacks")
    def __init__(self, profile_name):
        self.profile_name = profile_name
        self.providers = []
        self.engines = []
        self.callbacks = []
    def register_memory_provider(self, provider): self.providers.append(provider)
    def register_context_engine(self, engine): self.engines.append(engine)
    def on_unload(self, callback): self.callbacks.append(callback)

slot_a = SlotCollector("hermes-profile-a")
slot_a_fresh = SlotCollector("hermes-profile-a")
slot_b = SlotCollector("hermes-profile-b")
module.register(slot_a)
module.register(slot_a_fresh)
module.register(slot_b)
assert len(slot_a.providers) == len(slot_a.engines) == 1
assert not slot_a_fresh.providers and not slot_a_fresh.engines
assert len(slot_b.providers) == len(slot_b.engines) == 1
for callback in slot_a.callbacks:
    callback()
module.register(slot_a)
assert len(slot_a.providers) == len(slot_a.engines) == 2
slot_a_reloaded = SlotCollector("hermes-profile-a")
module.register(slot_a_reloaded)
assert not slot_a_reloaded.providers and not slot_a_reloaded.engines

functional_home = hermes_home.parent / "hermes-context-functional"
module.LLMBrainMemoryProvider().save_config({**saved_config, "timeout_seconds": 20}, str(functional_home))
engine = module.LLMBrainContextEngine(config={
    "vault_root": str(vault), "cli_path": cli, "project_id": "proj_hermes_self_check",
    # Keep the provider/context path bounded; the deliberately large
    # evidence-index fixture runs as the final bridge-only stress check below.
    "strategy": "lexical", "recall_budget_tokens": 4000, "timeout_seconds": 20,
})
engine.on_session_start("session-1", hermes_home=str(functional_home))
assert engine._config["timeout_seconds"] == 20
original = [{"role": "system", "content": "rules"}, {"role": "user", "content": "Hermes bridge contract"}]
selected = engine.select_context(original, conversation_messages=list(original), incoming_message=original[-1], budget_tokens=1000)
assert original == [{"role": "system", "content": "rules"}, {"role": "user", "content": "Hermes bridge contract"}]
assert selected and len(selected) == 3 and selected[1]["role"] == "system"
assert "provenance" in selected[1]["content"].lower()
selected_again = engine.select_context(
    selected, conversation_messages=list(selected), incoming_message=original[-1], budget_tokens=1000,
)
assert selected_again and sum(
    "<llm-brain-context>" in module._message_text(item.get("content"))
    for item in selected_again if isinstance(item, dict)
) == 1
assert isinstance(copy.deepcopy(engine), ContextEngine)
print("hermes_provider_context=ok")
PY

# Use Hermes' own environment for the native ContextCompressor contract when
# available; the isolated fake above remains the dependency-free plugin test.
hermes_python="$hermes_root/venv/bin/python"
if [ -x "$hermes_python" ]; then
  PYTHONPATH="$hermes_root" HERMES_HOME="$hermes_home" "$hermes_python" - "$repo_root" "$vault" <<'PY'
import copy
import importlib.util
import inspect
import sys
from pathlib import Path

repo_root, vault = map(Path, sys.argv[1:])
module_path = repo_root / "integrations/hermes/llm-brain/__init__.py"
spec = importlib.util.spec_from_file_location("llm_brain_hermes_native", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from agent.context_compressor import ContextCompressor

provider = module.LLMBrainMemoryProvider()
assert not inspect.isabstract(provider.__class__)
engine = module.LLMBrainContextEngine(config={
    "vault_root": str(vault), "cli_path": str(repo_root / "bin/llm-brain"),
    "project_id": "proj_hermes_self_check", "strategy": "lexical",
    "recall_budget_tokens": 4000, "timeout_seconds": 6,
}, model="openai/gpt-4o-mini")
assert isinstance(engine, ContextCompressor)
engine.update_from_response({"prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14})
assert engine.last_prompt_tokens == 10 and engine.last_total_tokens == 14
engine.update_model("openai/gpt-4o-mini", 32000)
assert engine.context_length == 32000 and engine.threshold_tokens > 0
clone = copy.deepcopy(engine)
assert isinstance(clone, ContextCompressor) and clone.model == engine.model
print("hermes_native_context=ok")
PY
fi

package_dir="$fixture/package"
"$repo_root/scripts/package-hermes-plugin.sh" "$package_dir" >/dev/null
[ -f "$package_dir/__init__.py" ]
[ "$(awk '$1 == "version:" { print $2; exit }' "$package_dir/plugin.yaml")" = "$(tr -d '[:space:]' <"$repo_root/VERSION")" ]
[ ! -e "$package_dir/__pycache__" ]
! find "$package_dir" -type f \( -name '*.pyc' -o -name '*.pyo' \) | grep -q .

# Exercise Hermes' real user-plugin discovery paths for both registrations.
mkdir -p "$hermes_home/plugins/llm-brain"
cp "$package_dir/__init__.py" "$package_dir/plugin.yaml" "$hermes_home/plugins/llm-brain/"
PYTHONPATH="$hermes_root" HERMES_HOME="$hermes_home" python3 - "$hermes_home" <<'PY' 2>/dev/null
import sys
import types
from pathlib import Path

home = Path(sys.argv[1])
from agent.context_engine import ContextEngine

class FakeCompressor(ContextEngine):
    def __init__(self, model=""):
        self.model = model
        self.threshold_percent = 0.5
        self.protect_first_n = 3
        self.protect_last_n = 20
        self.context_length = 1000
        self.threshold_tokens = 500
        self.last_prompt_tokens = self.last_completion_tokens = self.last_total_tokens = 0
        self.compression_count = 0
    def update_from_response(self, usage): pass
    def should_compress(self, prompt_tokens=None): return False
    def compress(self, messages, current_tokens=None, focus_topic=None, force=False, memory_context=""): return list(messages)

fake = types.ModuleType("agent.context_compressor")
fake.ContextCompressor = FakeCompressor
sys.modules["agent.context_compressor"] = fake

from plugins.memory import load_memory_provider
provider = load_memory_provider("llm-brain")
assert provider is not None and provider.name == "llm-brain"

import hermes_cli.plugins as plugins
manager = plugins.PluginManager()
manifest = manager._scan_directory(home / "plugins", source="user")[0]
manager._collect_directory_manifests = lambda: [manifest]
plugins._get_enabled_plugins = lambda: {"llm-brain"}
manager.discover_and_load(force=True)
assert manager._plugins["llm-brain"].enabled
assert manager._context_engine is not None and manager._context_engine.name == "llm-brain"
print("hermes_discovery=ok")
PY

run_loaded_index_check
printf '%s\n' 'llm-brain Hermes integration self-check passed'
