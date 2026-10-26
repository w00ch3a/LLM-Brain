#!/usr/bin/env bash
# 26 Oct idea 2: on Hermes >= 0.22.3 the plugin registers the post_compaction
# observer and re-injects a size-capped recall once, on the next pre_llm_call.
# On an older Hermes (no hook, or post_compaction not in VALID_HOOKS) nothing
# is registered.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes-compaction.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
vault="$fixture/vault"; workspace="$fixture/workspace"; mkdir -p "$workspace"
project_id="proj_hermes_compaction"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
cat >"$vault/projects/$project_id/okf/claims/deploy.md" <<'CLAIM'
---
type: Claim
title: Deploy window rule
description: Deploys go out on Tuesdays only.
status: stable
generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}
brain_project_id: proj_hermes_compaction
brain_review_state: approved
brain_source_authority: human-directive
brain_sensitivity: internal
brain_schema_version: 3
---
# Deploy window rule

Deploys go out on Tuesdays only, after the staging soak.
CLAIM
"$cli" --root "$vault" index build "$project_id" >/dev/null

python3 - "$repo_root" "$fixture" "$cli" "$vault" "$workspace" "$project_id" <<'PY'
import importlib.util, sys, types
from pathlib import Path

repo_root, fixture, cli, vault, workspace, project_id = sys.argv[1:]
fake = types.ModuleType("agent.context_compressor")
fake.ContextCompressor = type("ContextCompressor", (), {"__init__": lambda self, **_: None})
sys.modules["agent.context_compressor"] = fake

def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(repo_root) / "integrations/hermes/llm-brain/__init__.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class Ctx:
    def __init__(self, hooks=True):
        self.hooks = []
        if hooks:
            self.register_hook = lambda name, cb: self.hooks.append((name, cb))

def set_hermes(valid):
    pkg = types.ModuleType("hermes_cli"); pkg.__path__ = []
    plugins = types.ModuleType("hermes_cli.plugins"); plugins.VALID_HOOKS = set(valid)
    sys.modules["hermes_cli"] = pkg; sys.modules["hermes_cli.plugins"] = plugins

# Older Hermes: register_hook exists but post_compaction is unknown -> no-op.
set_hermes({"pre_llm_call", "post_llm_call"})
module = load("hermes_pc_old")
old = Ctx(); module.register(old)
assert old.hooks == [], old.hooks
# Oldest Hermes: no register_hook at all, no hermes_cli.plugins -> no-op.
sys.modules.pop("hermes_cli.plugins", None)
module = load("hermes_pc_older")
bare = Ctx(hooks=False); module.register(bare)
assert not hasattr(bare, "register_hook")

# Hermes 0.22.3+: both hooks register exactly once.
set_hermes({"pre_llm_call", "post_compaction"})
module = load("hermes_pc_new")
ctx = Ctx(); module.register(ctx); module.register(ctx)
assert [name for name, _ in ctx.hooks] == ["post_compaction", "pre_llm_call"], ctx.hooks
hooks = dict(ctx.hooks)

home = Path(fixture) / "hermes"
provider = module.LLMBrainMemoryProvider()
provider.save_config({"vault_root": vault, "cli_path": cli, "project_id": project_id, "strategy": "lexical",
                      "recall_budget_tokens": 4000, "timeout_seconds": 20, "post_compaction_budget_tokens": 120}, str(home))
provider.initialize("s1", hermes_home=str(home), agent_workspace=workspace, platform="cli",
                    agent_identity="self-check", user_id="tester", agent_context="primary")
history = [{"role": "user", "content": "When do deploys go out?"}, {"role": "assistant", "content": "Checking."}]

# No compaction yet: nothing injected.
assert hooks["pre_llm_call"](session_id="s1", user_message="deploy window", conversation_history=history) is None
# Tool-result pruning loses no conversation memory: no re-injection.
hooks["post_compaction"](session_id="s1", kind="prune_tool_results", reason="auto", old_session_id="", before_tokens=9, after_tokens=5, messages_removed=0)
assert hooks["pre_llm_call"](session_id="s1", user_message="deploy window", conversation_history=history) is None
# A summarising compaction re-injects once, capped by post_compaction_budget_tokens.
hooks["post_compaction"](session_id="s1", kind="summarize", reason="auto", old_session_id="s0", before_tokens=90000, after_tokens=20000, messages_removed=40)
out = hooks["pre_llm_call"](session_id="s1", user_message="deploy window rule", conversation_history=history)
assert isinstance(out, dict) and "context" in out, out
text = out["context"]
assert text.startswith("LLM-Brain memory re-attached after compaction (once; kind=summarize)"), text
assert "- Deploy window rule (okf/claims/deploy.md): Deploys go out on Tuesdays" in text, text
assert len(text.encode()) <= 120 * 4 + 40, len(text.encode())
assert hooks["pre_llm_call"](session_id="s1", user_message="deploy window rule", conversation_history=history) is None
# Default budget (625 tokens = 2500 bytes) carries the rendered recall.
provider.save_config({"post_compaction_budget_tokens": 625}, str(home))
provider.initialize("s2", hermes_home=str(home), agent_workspace=workspace, platform="cli", agent_identity="self-check", user_id="tester", agent_context="primary")
hooks["post_compaction"](session_id="s2", kind="micro_summarize", reason="auto")
out = hooks["pre_llm_call"](session_id="s2", user_message="deploy window rule", conversation_history=history)
assert out and "Tuesdays" in out["context"] and len(out["context"].encode()) <= 2500 + 40, out
# Opt-out key.
provider.save_config({"post_compaction_reinject": False}, str(home))
provider.initialize("s1", hermes_home=str(home), agent_workspace=workspace, platform="cli", agent_identity="self-check", user_id="tester", agent_context="primary")
hooks["post_compaction"](session_id="s1", kind="summarize", reason="manual")
assert hooks["pre_llm_call"](session_id="s1", user_message="deploy window rule", conversation_history=history) is None
print("hermes-post-compaction-self-check=ok")
PY
