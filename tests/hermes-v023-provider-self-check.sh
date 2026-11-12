#!/usr/bin/env bash
# Hermes >= 0.23 memory-provider contract, against a real Hermes checkout:
# initialize(resumed, message_count), on_turn_start(previous_message, model),
# the prefetch deadline, a subagent fork's required checkpoint under
# compression.checkpoint_required, and owner-only raw secret custody.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
hermes_root="${HERMES_SOURCE_ROOT:-$HOME/.hermes/hermes-agent}"
hermes_python="${HERMES_PYTHON:-$hermes_root/venv/bin/python}"
if [ ! -f "$hermes_root/agent/memory_provider.py" ] || [ ! -x "$hermes_python" ] \
  || ! grep -q 'previous_message' "$hermes_root/agent/memory_provider.py"; then
  printf 'Hermes >= 0.23 source unavailable; v0.23 provider checks skipped\n'
  exit 0
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes023.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
vault="$fixture/vault"
workspace="$fixture/workspace"
hermes_home="$fixture/hermes"
project_id="proj_hermes_v023"
mkdir -p "$workspace" "$hermes_home/plugins/llm-brain"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
cat >"$vault/projects/$project_id/okf/claims/bridge.md" <<'EOF'
---
type: Claim
title: Hermes resume contract
status: stable
generated: {by: "human:test", at: "2026-11-13T00:00:00Z"}
sources: [{resource: "self-check fixture"}]
brain_project_id: proj_hermes_v023
brain_review_state: approved
brain_source_authority: human-directive
brain_sensitivity: internal
brain_loading_temperature: hot
brain_schema_version: 3
---
# Hermes resume contract

The heron protocol keeps a resumed Hermes session warm.
EOF
cat >"$hermes_home/config.yaml" <<'EOF'
memory:
  provider: llm-brain
compression:
  checkpoint_required: true
EOF
package_dir="$fixture/package"
"$repo_root/scripts/package-hermes-plugin.sh" "$package_dir" >/dev/null
cp "$package_dir/__init__.py" "$package_dir/plugin.yaml" "$hermes_home/plugins/llm-brain/"

cd "$fixture"
PYTHONPATH="$hermes_root" HERMES_HOME="$hermes_home" "$hermes_python" - "$cli" "$vault" "$workspace" "$hermes_home" "$project_id" <<'PY'
import json, os, sys, time, types
from pathlib import Path

cli, vault, workspace, home, project_id = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5]
from plugins.memory import load_memory_provider
from agent.memory_manager import MemoryManager
from agent.conversation_compression import _pre_compress_memory_context
from agent.conversation_compression_checkpoint import checkpoint_required_from_config
from agent.agent_init_memory_provider import _stored_transcript_kwargs
from hermes_state import SessionDB

assert checkpoint_required_from_config() is True, "fixture config must arm compression.checkpoint_required"
config = {"vault_root": str(vault), "cli_path": cli, "project_id": project_id, "strategy": "lexical",
          "recall_budget_tokens": 2000, "timeout_seconds": 20}
(home / "llm-brain.json").write_text(json.dumps(config), encoding="utf-8")
episodes = vault / "projects" / project_id / "episodes"
outbox = home / "llm-brain" / "outbox"
count = lambda: len(list(episodes.rglob("*.md")))
committed = lambda: sorted((outbox / "committed").glob("*.md")) if (outbox / "committed").is_dir() else []

def manager_for(provider, session_id, **kwargs):
    m = MemoryManager()
    m.add_provider(provider)
    m.initialize_all(session_id=session_id, hermes_home=str(home), platform="cli",
                     agent_workspace=str(workspace), **kwargs)
    return m

# 1. resumed/message_count come from Hermes' own session store.
db = SessionDB(db_path=home / "state.db")
db.create_session("s-new", "cli")
db.append_message("s-new", "user", "first prompt")
db.create_session("s-old", "cli")
db.append_message("s-old", "user", "earlier question")
db.append_message("s-old", "assistant", "earlier answer")
new_kwargs = _stored_transcript_kwargs(types.SimpleNamespace(_session_db=db, session_id="s-new"))
old_kwargs = _stored_transcript_kwargs(types.SimpleNamespace(_session_db=db, session_id="s-old"))
assert new_kwargs == {"resumed": False, "message_count": 1}, new_kwargs
assert old_kwargs["resumed"] is True and old_kwargs["message_count"] == 2, old_kwargs

fresh = load_memory_provider("llm-brain")
assert fresh is not None and fresh.name == "llm-brain"
before = count()
manager_for(fresh, "s-new", agent_context="primary", **new_kwargs)
assert fresh._resumed is False and fresh._message_count == 1
time.sleep(0.5)
assert count() == before and not outbox.exists(), "a fresh session must not write at start-up"
print("initialize_fresh=ok")

# 2. A process died mid-capture; the resumed session finishes it and writes nothing else.
running = outbox / "running"
running.mkdir(parents=True)
orphan = (
    "---\ntype: HermesTurn\ntitle: \"Hermes turn orphan\"\nbrain_host: \"hermes\"\n"
    "brain_request_id: orphan0000000000000000\nbrain_processing_state: running\nbrain_attempts: 1\n"
    "brain_turn_kind: \"turn\"\nbrain_session_id: \"s-old\"\nbrain_principal: \"hermes:default\"\n"
    "brain_sensitivity: internal\nbrain_schema_version: 3\n---\n# Hermes turn orphan\n\nleft by a dead process\n"
)
(running / "999999-1-orphan0000000000000000.md").write_text(orphan, encoding="utf-8")
resumed = load_memory_provider("llm-brain")
before = count()
resumed_manager = manager_for(resumed, "s-old", agent_context="primary", **old_kwargs)
assert resumed._resumed is True and resumed._message_count == 2
deadline = time.time() + 60
while time.time() < deadline and not any("orphan0000" in p.name for p in committed()):
    time.sleep(0.5)
assert any("orphan0000" in p.name for p in committed()), "resumed start-up did not finish the orphaned capture"
assert count() == before + 1, (count(), before)
assert not list(running.glob("*.md"))
print("initialize_resumed_recovers_orphan=ok")

# 3. on_turn_start through the real manager: model kept; previous_message re-warms recall.
resumed_manager.on_turn_start(3, "next question", model="test/model-1", previous_message="heron protocol resumed session")
deadline = time.time() + 60
while time.time() < deadline and not resumed._warm:
    time.sleep(0.2)
assert resumed._model == "test/model-1" and resumed._turn_number == 3
warm = next(iter(resumed._warm.values()))
assert "heron protocol" in warm[1], warm
# A slow recall falls back to the warm context inside Hermes' 8 s prefetch timeout.
slow = home / "slow-cli"
slow.write_text("#!/bin/sh\nsleep 4\nexec \"%s\" \"$@\"\n" % cli, encoding="utf-8")
slow.chmod(0o700)
resumed._config = dict(resumed._config, cli_path=str(slow), prefetch_deadline_seconds=1.0)
started = time.time()
text = resumed_manager.prefetch_all("unrelated slow query", session_id="s-old")
assert time.time() - started < 3.5, "prefetch did not honour its deadline"
assert "still running" in text and "heron protocol" in text, text
resumed._config = dict(resumed._config, cli_path=cli, prefetch_deadline_seconds=6.5)
assert "heron protocol" in resumed_manager.prefetch_all("heron protocol", session_id="s-old")
print("on_turn_start_and_prefetch=ok")

# 4. A subagent fork compacts under checkpoint_required: the checkpoint saves, nothing blocks.
child = load_memory_provider("llm-brain")
fork = manager_for(child, "child-1", agent_context="subagent", parent_session_id="s-old")
assert child._agent_context == "subagent"
agent = types.SimpleNamespace(_memory_manager=fork, _persist_disabled=False, _session_db=None)
messages = [
    {"role": "system", "content": "sys"},
    {"role": "user", "content": [{"type": "text", "text": "fork task: check the heron gauge"}, {"type": "image_url", "image_url": {"url": "data:,"}}]},
    {"role": "assistant", "content": "", "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "x", "arguments": "{}"}}]},
    {"role": "tool", "tool_call_id": "t1", "content": "tool says 42"},
    {"role": "assistant", "content": "the heron gauge reads 42"},
]
before = count()
assert _pre_compress_memory_context(agent, messages, True) == ""
assert count() == before + 1, "fork checkpoint was not durable"
record = [p.read_text(encoding="utf-8") for p in committed() if "fork task" in p.read_text(encoding="utf-8")]
assert record and '"agent_context": "subagent"' in record[0] and '"parent_session_id": "s-old"' in record[0]
assert "image_url part not checkpointed" in record[0] and "brain_bridge_receipt_sha256:" in record[0]
# Same window again: idempotent, still no block.
assert _pre_compress_memory_context(agent, messages, True) == "" and count() == before + 1
# A tool-only window has nothing direct to keep and must not block either.
tool_only = [{"role": "assistant", "content": None, "tool_calls": [{"id": "t2", "type": "function", "function": {"name": "y", "arguments": "{}"}}]},
             {"role": "tool", "tool_call_id": "t2", "content": "only tools"}]
assert _pre_compress_memory_context(agent, tool_only, True) == "" and count() == before + 1
# Fork turn hooks stay off: no sync, and an unrequired pre-compress writes nothing.
before_outbox = sorted(p.name for p in outbox.rglob("*.md"))
fork.sync_all("fork user", "fork assistant", session_id="child-1")
child.on_pre_compress(messages)
time.sleep(0.5)
assert sorted(p.name for p in outbox.rglob("*.md")) == before_outbox
print("subagent_checkpoint_does_not_block=ok")

# 5. Hermes scrubs secrets on every hand-off. Default: kept as handed over and labelled.
fake_secret = "sk-proj-" + "TESTONLY" * 5          # synthetic, matches Hermes' sk- pattern
primary = load_memory_provider("llm-brain")
db.create_session("s-sec", "cli")
db.append_message("s-sec", "user", f"store the deploy key {fake_secret} for later")
db.append_message("s-sec", "assistant", "noted")
sec_manager = manager_for(primary, "s-sec", agent_context="primary")
sec_messages = [{"role": "user", "content": f"store the deploy key {fake_secret} for later"}, {"role": "assistant", "content": "noted"}]
before = count()
sec_manager.on_pre_compress(sec_messages, evidence_messages=sec_messages, require_checkpoint=True)
assert count() == before + 1
sources = vault / "projects" / project_id / "sources"
stored = [p.read_text(encoding="utf-8") for p in sorted(sources.rglob("*.md"), key=lambda q: q.stat().st_mtime) if "deploy key" in p.read_text(encoding="utf-8")]
assert stored and fake_secret not in stored[-1] and "sk-pro..." in stored[-1] and '"egress_scrubbed": 1' in stored[-1]
assert "brain_sensitivity: internal" in stored[-1]
print("egress_scrub_labelled=ok")

# Opt-in raw custody: the original comes back byte for byte from Hermes' own store, owner-only.
config["raw_secret_custody"] = True
(home / "llm-brain.json").write_text(json.dumps(config), encoding="utf-8")
custodian = load_memory_provider("llm-brain")
cust_manager = manager_for(custodian, "s-sec", agent_context="primary")
before = count()
cust_manager.on_pre_compress(sec_messages + [{"role": "user", "content": "and again"}],
                             evidence_messages=sec_messages + [{"role": "user", "content": "and again"}], require_checkpoint=True)
assert count() == before + 1
raw = [p for p in sources.rglob("*.md") if fake_secret in p.read_text(encoding="utf-8")]
assert len(raw) == 1, "raw original was not kept byte for byte"
body = raw[0].read_text(encoding="utf-8")
assert f"store the deploy key {fake_secret} for later" in body
assert "brain_sensitivity: restricted" in body or "brain_owner_only: true" in body, "raw custody must be owner-only"
assert '"egress_restored": 1' in body
Path(sys.argv[4], "raw-episode.txt").write_text(str(raw[0].relative_to(vault / "projects" / project_id)), encoding="utf-8")
print("raw_secret_custody_owner_only=ok")
PY

# Recall as the owner principal: the scrubbed internal record renders, the restricted raw one never does.
raw_rel="$(cat "$hermes_home/raw-episode.txt")"
printf '%s\n' 'deploy key for later' >"$fixture/q.txt"
recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --principal "hermes:default" --query-file "$fixture/q.txt" --strategy lexical)"
case "$recall" in *'"status": "ok"'*|*'"status":"ok"'*) ;; *) printf 'recall failed: %s\n' "$recall" >&2; exit 1 ;; esac
case "$recall" in *"sk-pro..."*) ;; *) printf 'recall did not return the scrubbed internal record (vacuous check)\n' >&2; exit 1 ;; esac
case "$recall" in *"TESTONLY"*) printf 'raw secret rendered in recall\n' >&2; exit 1 ;; esac
case "$recall" in *"$raw_rel"*) printf 'raw episode rendered in recall\n' >&2; exit 1 ;; esac
printf 'raw_secret_never_rendered_in_recall=ok\n'
printf 'llm-brain Hermes v0.23 provider self-check passed\n'
