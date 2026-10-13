#!/usr/bin/env bash
# Neural Expansion inside Hermes: the /neural-expansion slash command and the
# dashboard page, loaded through Hermes' real plugin manager and dashboard
# discovery (pinned source).  Proves: demo works with no setting; real-brain
# export is refused until `neural_expansion_export: true`; exports are 0600,
# principal-filtered and carry label lineage; the dashboard API refuses
# non-loopback clients and pins a no-network CSP.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
hermes_root="${HERMES_SOURCE_ROOT:-$HOME/.hermes/hermes-agent}"
hermes_python="${HERMES_PYTHON:-$hermes_root/venv/bin/python}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes-ne.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'hermes neural expansion self-check: %s\n' "$*" >&2; exit 1; }

if [ ! -d "$hermes_root" ] || [ ! -x "$hermes_python" ]; then
  [ "${LLM_BRAIN_REQUIRE_REAL_HERMES:-0}" = 0 ] || fail "real Hermes source required: $hermes_root"
  printf 'Hermes source unavailable; Neural Expansion Hermes checks skipped\n'
  exit 0
fi

vault="$fixture/vault"; workspace="$fixture/workspace"; hermes_home="$fixture/hermes"
project_id="proj_hermes_ne_check"
mkdir -p "$workspace" "$hermes_home/plugins"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
claims="$vault/projects/$project_id/okf/claims"
for id in alpha beta secret; do
  principal_line=""; [ "$id" != secret ] || principal_line='brain_principal: ["someone-else"]'
  cat >"$claims/$id.md" <<EOT
---
type: Claim
title: "Record $id"
status: stable
generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}
sources: [{resource: "fixture"}]
brain_project_id: $project_id
brain_review_state: approved
brain_source_authority: human-directive
brain_sensitivity: internal
$principal_line
brain_schema_version: 3
---
# Record $id

Synthetic record $id.
EOT
done
"$cli" --root "$vault" label add "$project_id" okf/claims/beta.md superseded-by --target okf/claims/alpha.md --reason 'fixture' >/dev/null
"$cli" --root "$vault" label add "$project_id" okf/claims/alpha.md decision-point:storage --reason 'fixture' >/dev/null
"$cli" --root "$vault" index build "$project_id" >/dev/null
# A second, empty project for the merged "View all" page.
mkdir -p "$fixture/workspace2"
"$cli" --root "$vault" project ensure "$fixture/workspace2" --id proj_hermes_ne_second >/dev/null
"$cli" --root "$vault" index build proj_hermes_ne_second >/dev/null

package_dir="$fixture/package"
"$repo_root/scripts/package-hermes-plugin.sh" "$package_dir" >/dev/null
[ -f "$package_dir/dashboard/manifest.json" ] && [ -f "$package_dir/dashboard/plugin_api.py" ] && [ -f "$package_dir/dashboard/dist/index.js" ] || fail 'dashboard files not packaged'
grep -Fq "\"version\": \"$(tr -d '[:space:]' <"$repo_root/VERSION")\"" "$package_dir/dashboard/manifest.json" || fail 'dashboard manifest version not stamped'
cp -R "$package_dir" "$hermes_home/plugins/llm-brain"
printf '{"vault_root": "%s", "cli_path": "%s", "project_id": "%s"}\n' "$vault" "$cli" "$project_id" >"$hermes_home/llm-brain.json"

PYTHONPATH="$hermes_root" HERMES_HOME="$hermes_home" TERMINAL_CWD="$workspace" HERMES_AGENT_IDENTITY=default "$hermes_python" - "$hermes_home" "$project_id" <<'PY'
import json, os, stat, sys, types
from pathlib import Path
home, project_id = Path(sys.argv[1]), sys.argv[2]

from agent.context_engine import ContextEngine
class FakeCompressor(ContextEngine):
    def __init__(self, model=""):
        self.model = model; self.threshold_percent = 0.5; self.protect_first_n = 3; self.protect_last_n = 20
        self.context_length = 1000; self.threshold_tokens = 500
        self.last_prompt_tokens = self.last_completion_tokens = self.last_total_tokens = 0; self.compression_count = 0
    def update_from_response(self, usage): pass
    def should_compress(self, prompt_tokens=None): return False
    def compress(self, messages, current_tokens=None, focus_topic=None, force=False, memory_context=""): return list(messages)
fake = types.ModuleType("agent.context_compressor"); fake.ContextCompressor = FakeCompressor
sys.modules["agent.context_compressor"] = fake

import hermes_cli.plugins as plugins
manager = plugins.PluginManager()
manifest = manager._scan_directory(home / "plugins", source="user")[0]
manager._collect_directory_manifests = lambda: [manifest]
plugins._get_enabled_plugins = lambda: {"llm-brain"}
manager.discover_and_load(force=True)
assert "neural-expansion" in manager._plugin_commands, sorted(manager._plugin_commands)
handler = manager._plugin_commands["neural-expansion"]["handler"]

def mode_bits(path): return stat.S_IMODE(Path(path).stat().st_mode)

reply = handler("")
assert "synthetic demo data" in reply and "file://" in reply, reply
demo = Path(reply.split("Private file (0600): ", 1)[1].strip())
assert demo.is_file() and mode_bits(demo) == 0o600 and mode_bits(demo.parent) == 0o700, (demo, oct(mode_bits(demo)))
assert str(demo).startswith(str((home / "neural-expansion").resolve())), demo

reply = handler("export")
assert "real-brain export is off" in reply, reply
# $HERMES_HOME/neural-expansion pointing into the vault is refused.
import shutil
shutil.rmtree(home / "neural-expansion"); (home / "neural-expansion").symlink_to(Path(json.loads((home / "llm-brain.json").read_text())["vault_root"]))
reply = handler("")
assert "inside the vault" in reply, reply
(home / "neural-expansion").unlink()
reply = handler("bogus")
assert "mode must be demo or export" in reply, reply

config = json.loads((home / "llm-brain.json").read_text()); config["neural_expansion_export"] = True
(home / "llm-brain.json").write_text(json.dumps(config))
reply = handler("export")
assert "principal-filtered" in reply, reply
page_path = Path(reply.split("Private file (0600): ", 1)[1].strip())
page = page_path.read_text()
assert mode_bits(page_path) == 0o600
assert "Record alpha" in page and "Record secret" not in page, "principal filter failed"
assert "decision-point:storage" in page and "label:superseded-by" in page, "label lineage missing from export"

# Dashboard: Hermes' own discovery finds the page and its API.
import hermes_cli.web_server_dashboard as dash
found = [p for p in dash._discover_dashboard_plugins() if p["name"] == "llm-brain"]
assert found and found[0]["has_api"] and found[0]["tab"]["path"] == "/neural-expansion", found
assert dash._plugin_api_mount_skip_reason(found[0], {"llm-brain"}, set()) is None
assert dash._plugin_api_mount_skip_reason(found[0], set(), set()) == "not in plugins.enabled"

import importlib.util
spec = importlib.util.spec_from_file_location("ne_api", Path(found[0]["_dir"]) / found[0]["_api_file"])
api = importlib.util.module_from_spec(spec); spec.loader.exec_module(api)
from fastapi import FastAPI
from fastapi.testclient import TestClient
app = FastAPI(); app.include_router(api.router, prefix="/api/plugins/llm-brain")
local = TestClient(app, client=("127.0.0.1", 50000))
assert local.get("/api/plugins/llm-brain/status").json()["export_enabled"] is True
body = local.get("/api/plugins/llm-brain/view", params={"mode": "export"}).json()
assert body["data"] == "principal-filtered" and "connect-src 'none'" in body["html"] and "Record secret" not in body["html"], body.keys()
assert local.get("/api/plugins/llm-brain/view", params={"mode": "demo"}).json()["data"] == "synthetic"
# Served copies are removed after the page is returned.
assert not list((home / "neural-expansion").glob("*.html")) or all(p == page_path for p in (home / "neural-expansion").glob("*.html")), list((home / "neural-expansion").iterdir())
# Project picker: counts only, explicit project export, unknown ids refused.
rows = local.get("/api/plugins/llm-brain/projects").json()["projects"]
row = [r for r in rows if r["project_id"] == project_id]
assert row and row[0]["records"] >= 3 and set(row[0]) == {"project_id", "alias", "records", "relations", "pending_review"}, rows
body = local.get("/api/plugins/llm-brain/view", params={"mode": "export", "project": project_id}).json()
assert body["project_id"] == project_id and "Record alpha" in body["html"]
assert local.get("/api/plugins/llm-brain/view", params={"mode": "export", "project": "nope"}).status_code == 500
assert "unknown project" in handler("export nope")
listing = handler("projects")
assert project_id in listing and "Record" not in listing, listing
# View all: background merged build with progress, page served once then removed.
import time
started = local.get("/api/plugins/llm-brain/view-all/start").json()
assert started["status"] == "started" and started["total"] == 2, started
for _ in range(240):
    state = local.get("/api/plugins/llm-brain/view-all/status", params={"job": started["job"]}).json()
    if state["status"] == "ok":
        break
    assert state["status"] == "running" and 0 <= state["done"] <= 2, state
    time.sleep(0.5)
assert state["status"] == "ok" and state["done"] == 2 and state["skipped"] == 0, {k: state[k] for k in state if k != "html"}
assert "project/" + project_id in state["html"] and "project/proj_hermes_ne_second" in state["html"]
assert "Record alpha" in state["html"] and "Record secret" not in state["html"] and "connect-src 'none'" in state["html"]
assert not list((home / "neural-expansion").glob("neural-expansion-all-*.html")), "served All projects copy not removed"
assert local.get("/api/plugins/llm-brain/view-all/status", params={"job": started["job"]}).status_code == 404
remote = TestClient(app, client=("192.0.2.10", 50000))
assert remote.get("/api/plugins/llm-brain/view-all/start").status_code == 403
assert remote.get("/api/plugins/llm-brain/view-all/status", params={"job": "x"}).status_code == 403
assert remote.get("/api/plugins/llm-brain/view").status_code == 403
assert remote.get("/api/plugins/llm-brain/status").status_code == 403
assert remote.get("/api/plugins/llm-brain/projects").status_code == 403
print("hermes_neural_expansion=ok")
PY
printf 'hermes neural expansion self-check passed\n'
