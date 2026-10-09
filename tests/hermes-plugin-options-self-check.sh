#!/usr/bin/env bash
# Dependency-free checks for the Hermes plugin's opt-in options (0.8.1):
# optional configuration keys, the local Laya recall filter and its fallbacks,
# process-group bridge timeouts and context-engine registration modes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes-options.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

python3 - "$repo_root" "$fixture" <<'PY'
import http.server
import importlib.util
import json
import os
import socketserver
import sys
import threading
import time
import types
from pathlib import Path

repo_root, fixture = map(Path, sys.argv[1:])

class FakeCompressor:
    def __init__(self, model="", **_):
        self.model = model

fake = types.ModuleType("agent.context_compressor")
fake.ContextCompressor = FakeCompressor
sys.modules["agent.context_compressor"] = fake
spec = importlib.util.spec_from_file_location("llm_brain_hermes_options", repo_root / "integrations/hermes/llm-brain/__init__.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# --- configuration: six core keys unchanged, opt-in keys only when set -------
assert len(module.CONFIG_KEYS) == 6
assert not module.CONFIG_KEYS & module.OPTIONAL_CONFIG_KEYS
home = fixture / "home"
core = {"vault_root": str(fixture / "vault"), "cli_path": "llm-brain", "project_id": "",
        "strategy": "lexical", "recall_budget_tokens": 4000, "timeout_seconds": 6}
module._write_config(dict(core, unsupported_setting="x"), home)
saved = json.loads((home / "llm-brain.json").read_text())
assert set(saved) == module.CONFIG_KEYS, saved
assert set(module._load_config(None)) == module.CONFIG_KEYS

# Companion-owned keys already in the file survive a setup rewrite.
data = dict(saved, companion_owned_setting=True)
(home / "llm-brain.json").write_text(json.dumps(data))
module._write_config({"timeout_seconds": 9}, home)
saved = json.loads((home / "llm-brain.json").read_text())
assert saved["companion_owned_setting"] is True and saved["timeout_seconds"] == 9
assert "laya_url" not in saved and "context_engine_registration" not in saved

module._write_config({"laya_url": " http://127.0.0.1:9/decide ", "laya_max_candidates": 99,
                      "laya_min_relevance": 7, "laya_min_margin": "bad",
                      "context_engine_registration": "When_Selected"}, home)
saved = json.loads((home / "llm-brain.json").read_text())
assert saved["laya_url"] == "http://127.0.0.1:9/decide"
assert saved["laya_max_candidates"] == 4 and saved["laya_min_relevance"] == 1.0 and saved["laya_min_margin"] == 0.1
assert saved["context_engine_registration"] == "when-selected"
assert module._load_config(home) == {k: v for k, v in saved.items() if k in module.CONFIG_KEYS | module.OPTIONAL_CONFIG_KEYS}
(home / "llm-brain.json").write_text(json.dumps(dict(core, context_engine_registration="sometimes")))
assert module._load_config(home)["context_engine_registration"] == "always"

# --- Laya endpoint policy: local or private-network literals only -----------
for url in ("http://localhost:8080/v1", "http://127.0.0.1:9/x", "https://10.0.0.1/x", "http://[::1]:9/x", "http://192.168.0.10/x"):
    module._local_laya_endpoint(url)
for url in ("http://example.com/x", "http://100.64.0.1/x", "ftp://127.0.0.1/x", "http://user:pw@127.0.0.1/x", "http://127.0.0.1:99999/x", "", "not a url"):
    try:
        module._local_laya_endpoint(url)
    except ValueError:
        pass
    else:
        raise AssertionError(f"endpoint accepted: {url}")

# --- Laya selection --------------------------------------------------------
def payload(count=3):
    rows = [{"path": f"okf/claims/c{i}.md", "title": f"Claim {i}", "excerpt": f"excerpt {i}", "score": 1.0 - i / 10} for i in range(count)]
    context = "## LLM-Brain recall\n\nheader\n" + "".join(
        f"### Claim {i}\nReference: `okf/claims/c{i}.md`\n\nbody {i}\n" for i in range(count))
    return {"status": "ok", "results": rows, "context_markdown": context}

def answers(scores, triage="answer"):
    out = {"triage": {"type": "choice", "choice": triage}}
    for i, value in enumerate(scores):
        out[f"relevance_{i}"] = {"type": "noul", "noul": value}
    return {"answers": out}

config = dict(core, laya_url="http://127.0.0.1:9/decide")
sent = []
def transport_for(response):
    def transport(url, body, timeout):
        sent.append((url, body, timeout))
        if isinstance(response, Exception):
            raise response
        return response
    return transport

# Disabled unless laya_url is configured: payload untouched, no transport call.
untouched = module._apply_laya_selection(dict(core), "q", payload(), transport=transport_for(answers([0.9, 0.1, 0.1])))
assert "local_laya" not in untouched and len(untouched["results"]) == 3 and not sent

selected = module._apply_laya_selection(config, "which claim?", payload(), transport=transport_for(answers([0.95, 0.2, 0.1])))
assert selected["local_laya"]["status"] == "ok" and selected["local_laya"]["selected_count"] == 1
assert [row["path"] for row in selected["results"]] == ["okf/claims/c0.md"]
assert "c0.md" in selected["context_markdown"] and "c1.md" not in selected["context_markdown"]
assert selected["context_markdown"].startswith("## LLM-Brain recall")
url, body, timeout = sent[-1]
assert timeout == 4 and body["model"] == "laya-typed-decisions" and len(body["state"]["candidates"]) == 3

def unchanged(result, status):
    assert result["local_laya"]["status"] == status, result["local_laya"]
    assert len(result["results"]) == 3 and "c2.md" in result["context_markdown"]

unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for(answers([0.6, 0.52, 0.1]))), "ambiguous")
unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for(answers([0.1, 0.1, 0.1]))), "ambiguous")
unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for(TimeoutError("timed out"))), "unavailable")
unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for(OSError("refused"))), "unavailable")
unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for({"answers": {"triage": {"type": "choice", "choice": "nope"}}})), "unavailable")
unchanged(module._apply_laya_selection(config, "q", payload(), transport=transport_for(answers([1.5, 0.1, 0.1]))), "unavailable")
unchanged(module._apply_laya_selection(dict(config, laya_url="http://example.com/x"), "q", payload(), transport=transport_for(answers([0.9, 0.1, 0.1]))), "unavailable")
limited = module._apply_laya_selection(config, "q", payload(6), transport=transport_for(answers([0.9] * 6)))
assert limited["local_laya"]["status"] == "candidate_limit" and len(limited["results"]) == 6

# Sensitive query text is redacted before it leaves the process.
module._apply_laya_selection(config, "api_key=abcdefabcdefabcdef", payload(), transport=transport_for(answers([0.9, 0.1, 0.1])))
assert "abcdefabcdefabcdef" not in json.dumps(sent[-1][1])

# Real local HTTP: a slow endpoint times out and recall stays unfiltered; a
# responsive one filters. Redirects are refused.
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        if self.path == "/slow":
            time.sleep(3)
        if self.path == "/redirect":
            self.send_response(302); self.send_header("Location", "/fast"); self.end_headers(); return
        count = len(request["state"]["candidates"])
        body = json.dumps(answers([0.9] + [0.05] * (count - 1))).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address): pass  # client timeouts close the socket early

server = Server(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
started = time.monotonic()
slow = module._apply_laya_selection(dict(config, laya_url=f"http://127.0.0.1:{port}/slow", laya_timeout_seconds=1), "q", payload())
assert time.monotonic() - started < 2.5
unchanged(slow, "unavailable")
fast = module._apply_laya_selection(dict(config, laya_url=f"http://127.0.0.1:{port}/fast"), "q", payload())
assert fast["local_laya"]["status"] == "ok" and len(fast["results"]) == 1
unchanged(module._apply_laya_selection(dict(config, laya_url=f"http://127.0.0.1:{port}/redirect"), "q", payload()), "unavailable")
server.shutdown()

# Recall wiring: the filter runs after normal bridge recall.
real_bridge = module._bridge_call
module._bridge_call = lambda cfg, source, args: payload()
recalled = module._recall(dict(config, laya_url=f"http://127.0.0.1:{port}/gone", laya_timeout_seconds=1), None, fixture, "hermes:test", "query")
assert recalled["local_laya"]["status"] == "unavailable" and len(recalled["results"]) == 3
module._bridge_call = real_bridge

# --- bridge timeout covers the whole process group --------------------------
slow_cli = fixture / "slow-cli"
marker = fixture / "grandchild.pid"
slow_cli.write_text(
    "#!/usr/bin/env bash\n"
    f"sleep 30 & echo $! > '{marker}'\n"
    "sleep 30\n", encoding="utf-8")
slow_cli.chmod(0o700)
started = time.monotonic()
assert module._bridge_call(dict(core, cli_path=str(slow_cli), timeout_seconds=1), fixture, ["recall"]) is None
assert time.monotonic() - started < 4.0, time.monotonic() - started
time.sleep(0.2)
grandchild = int(marker.read_text().strip())
try:
    os.kill(grandchild, 0)
    alive = True
except ProcessLookupError:
    alive = False
except PermissionError:
    alive = True
assert not alive, "bridge timeout left a descendant running"

env_cli = fixture / "env-cli"
env_cli.write_text(
    "#!/usr/bin/env python3\nimport json, os\n"
    "print(json.dumps({'status': 'ok', 'wait': os.environ.get('LLM_BRAIN_LOCK_WAIT_SECONDS'), 'context_markdown': '', 'results': []}))\n",
    encoding="utf-8")
env_cli.chmod(0o700)
env_payload = module._bridge_call(dict(core, cli_path=str(env_cli)), fixture, ["status"])
assert env_payload and env_payload.get("wait") == "2", env_payload
os.environ["LLM_BRAIN_LOCK_WAIT_SECONDS"] = "7"
assert module._bridge_call(dict(core, cli_path=str(env_cli)), fixture, ["status"]).get("wait") == "7"
del os.environ["LLM_BRAIN_LOCK_WAIT_SECONDS"]

# --- context-engine registration modes -------------------------------------
selected_engine = {"value": "compressor"}
config_pkg = types.ModuleType("hermes_cli")
config_mod = types.ModuleType("hermes_cli.config")
config_mod.load_config = lambda: {"context": {"engine": selected_engine["value"]}}
config_pkg.config = config_mod
sys.modules["hermes_cli"] = config_pkg
sys.modules["hermes_cli.config"] = config_mod

class Collector:
    def __init__(self):
        self.providers, self.engines = [], []
    def register_memory_provider(self, provider): self.providers.append(provider)
    def register_context_engine(self, engine): self.engines.append(engine)

def register_with(mode):
    reg_home = fixture / f"reg-{mode}-{selected_engine['value']}"
    reg_home.mkdir(parents=True, exist_ok=True)
    values = dict(core)
    if mode:
        values["context_engine_registration"] = mode
    (reg_home / "llm-brain.json").write_text(json.dumps(values))
    os.environ["HERMES_HOME"] = str(reg_home)
    collector = Collector()
    module.register(collector)
    return collector

collector = register_with(None)
assert len(collector.providers) == 1 and len(collector.engines) == 1  # default unchanged
collector = register_with("always")
assert len(collector.engines) == 1
collector = register_with("when-selected")
assert len(collector.providers) == 1 and not collector.engines
selected_engine["value"] = "llm-brain"
collector = register_with("when-selected")
assert len(collector.providers) == 1 and len(collector.engines) == 1
print("hermes_plugin_options=ok")
PY
printf '%s\n' 'llm-brain Hermes plugin options self-check passed'
