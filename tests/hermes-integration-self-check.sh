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
printf '%s\n' "$recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); c=p["context_markdown"]; assert p["status"] == "ok"; assert p["results"]; assert "okf/claims/bridge.md" in p["evidence_refs"]; assert p["actual_strategy"] == "lexical"; assert "Hermes bridge contract" in c; assert len(c.encode("utf-8")) <= 16000; assert c.endswith(".\n")'
tiny_recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --strategy lexical --budget-tokens 1)"
printf '%s\n' "$tiny_recall" | python3 -c 'import json,sys; assert len(json.load(sys.stdin)["context_markdown"].encode("utf-8")) <= 4'

if [ ! -d "$hermes_root" ]; then
  printf 'Hermes source unavailable; bridge checks passed, provider checks skipped\n'
  exit 0
fi

PYTHONPATH="$hermes_root" TERMINAL_CWD="$workspace" HERMES_HOME="$hermes_home" python3 - "$repo_root" "$vault" "$workspace" "$hermes_home" <<'PY'
import copy
import importlib.util
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
assert module._workspace(hermes_home, "hermes") == (hermes_home / "workspace/hermes").resolve()

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
slow_cli = hermes_home / "slow-bridge"
slow_cli.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(5)\n", encoding="utf-8")
slow_cli.chmod(0o700)
started = time.monotonic()
assert module._bridge_call({**saved_config, "cli_path": str(slow_cli), "timeout_seconds": 1}, workspace, ["recall"]) is None
assert time.monotonic() - started < 2.0

provider = module.LLMBrainMemoryProvider()
provider.initialize("session-1", hermes_home=str(hermes_home), agent_workspace=str(workspace), platform="cli", agent_identity="self-check", user_id="self-check-user", agent_context="primary")
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
    def __init__(self): self.provider = None
    def register_memory_provider(self, provider): self.provider = provider
class ContextCollector:
    def __init__(self): self.engine = None
    def register_context_engine(self, engine): self.engine = engine
memory_collector = MemoryCollector()
context_collector = ContextCollector()
module.register(memory_collector)
module.register(context_collector)
assert memory_collector.provider.name == "llm-brain"
assert context_collector.engine.name == "llm-brain"
assert isinstance(context_collector.engine, ContextEngine)

engine = module.LLMBrainContextEngine(config={
    "vault_root": str(vault), "cli_path": cli, "project_id": "proj_hermes_self_check",
    "strategy": "lexical", "recall_budget_tokens": 4000, "timeout_seconds": 6,
})
engine.on_session_start("session-1", hermes_home=str(hermes_home))
original = [{"role": "system", "content": "rules"}, {"role": "user", "content": "Hermes bridge contract"}]
selected = engine.select_context(original, conversation_messages=list(original), incoming_message=original[-1], budget_tokens=1000)
assert original == [{"role": "system", "content": "rules"}, {"role": "user", "content": "Hermes bridge contract"}]
assert selected and len(selected) == 3 and selected[1]["role"] == "system"
assert "provenance" in selected[1]["content"].lower()
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

printf '%s\n' 'llm-brain Hermes integration self-check passed'
