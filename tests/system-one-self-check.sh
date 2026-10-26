#!/usr/bin/env bash
# Memthena models: System One is opt-in and fail-open; it only moves AUTO to
# WAIT (never promotes); protected items never reach a model; acting heads are
# keep/dup/rel (32m int8) or dup only (linear fallback); kind and triage are
# advisory; Hermes accepts the decide() response. The bundled embedder is
# opt-in (MEMTHENA_EMBED=1) and produces vectors.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-s1.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
unset MEMTHENA_S1 MEMTHENA_S1_MODEL MEMTHENA_S1_BACKEND MEMTHENA_EMBED
[ -f "$repo_root/models/memthena-s1-lin/memthena-s1-lin.s1lin" ] || { echo 'system-one-self-check: skipped (no bundled models)'; exit 0; }
python3 - "$repo_root" "$fixture" <<'PY'
import json, os, sys, importlib.util
repo, fx = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "lib"))
import memthena_s1 as s1, review_policy as rp
from pathlib import Path
def fail(m): print("system-one-self-check:", m, file=sys.stderr); sys.exit(1)
os.environ["MEMTHENA_S1_BACKEND"] = "lin"
spec = s1.bundled_spec(); lin = s1.load_predictor("bundled")
if not spec.startswith("lin:") or s1.acting(lin) != {"dup"}: fail("linear fallback must be dup-only")
# decide(): Jev-shaped, relevance neutral without an acting rel head, kind/triage advisory.
req = {"model": "x", "state": {"task": "when does the ferry leave", "candidates": [{"title": "Ferry", "excerpt": "The ferry leaves at nine."}, {"title": "Kernel", "excerpt": "Kernel cache flags."}]},
       "questions": {"triage": {"type": "choice", "criteria": s1.TRIAGE}, "relevance_0": {"type": "noul"}, "relevance_1": {"type": "noul"}}}
resp = s1.decide(req, lin)
if [resp["answers"][k]["noul"] for k in ("relevance_0", "relevance_1")] != [1.0, 1.0]: fail("linear relevance must be neutral")
if resp["advisory"] != ["kind", "triage"]: fail("kind/triage must be advisory")
spec_h = importlib.util.spec_from_file_location("hp", os.path.join(repo, "integrations/hermes/llm-brain/__init__.py"))
try:
    hp = importlib.util.module_from_spec(spec_h); spec_h.loader.exec_module(hp)
except Exception as exc:  # plugin needs a Hermes host; validator check skipped
    hp = None
if hp is not None:
    hp._validate_laya_answers(resp, req["questions"], 2); print("system-one-self-check: Hermes validator accepts decide()")
# Review hook: build a project with AUTO-able items.
proj = Path(fx) / "p"; (proj / "review").mkdir(parents=True); (proj / "okf" / "claims").mkdir(parents=True)
(proj / "okf" / "claims" / "c1.md").write_text("---\ntype: Claim\ntitle: Ferry timetable\n---\n# Ferry timetable\n\nThe harbour ferry leaves every twenty minutes on weekdays from pier two.\n")
def item(name, body, extra=""):
    t = f"---\ntype: ReviewItem\ntitle: \"{name}\"\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: internal\nbrain_source_authority: user\n{extra}---\n# {name}\n\n{body}\n"
    (proj / "review" / f"{name}.md").write_text(t)
item("dup1", "The harbour ferry leaves every twenty minutes on weekdays from pier two.")
item("new1", "Deploys run from the release branch after the gate script passes on every machine.")
item("sec1", "The harbour ferry password: Q7xZZZZZZZZZZZZZZZZZZZZ is shared.")
class Probe:  # records every text a model would see
    seen = []
    def __init__(self, real): self.real = real; self.temps = real.temps; self.tag = real.tag
    def logits(self, head, pairs):
        Probe.seen += [a + " " + (b or "") for a, b in pairs]; return self.real.logits(head, pairs)
project = rp.Project(proj); settings = rp.Settings(dict(os.environ))
base = [(i.id, t, r) for i, t, r in rp.plan(project, settings)]
for env in ({"MEMTHENA_S1_MODEL": "lin:x:/nonexistent.s1lin"}, {"MEMTHENA_S1_MODEL": "garbage"}):
    os.environ.update(env); rp._S1.clear()
    if [(i.id, t, r) for i, t, r in rp.plan(rp.Project(proj), settings)] != base: fail(f"broken model changed the plan: {env}")
    os.environ.pop("MEMTHENA_S1_MODEL")
os.environ["MEMTHENA_S1"] = "1"; rp._S1.clear(); rp._S1["pred"] = Probe(lin)
withm = [(i.id, t, r) for i, t, r in rp.plan(rp.Project(proj), settings)]
for (a, t0, r0), (b, t1, r1) in zip(base, withm):
    if t0 != t1 and not (t0.startswith("AUTO") and t1 == "WAIT"): fail(f"model did more than AUTO->WAIT: {a} {t0}->{t1}")
items = {i.id: i for i in rp.load_items(rp.Project(proj))}
os.environ["MEMTHENA_S1_THRESHOLD"] = "0.9"  # lin scores this exact duplicate ~0.92
direct = {k: rp._s1_cautious(v, "AUTO", "rules", rp.Project(proj)) for k, v in items.items()}
if any(t not in ("AUTO", "WAIT") for t, _ in direct.values()): fail(f"hook produced a non AUTO/WAIT tier: {direct}")
if direct["dup1"] != ("WAIT", "s1-possible-duplicate"): fail(f"exact duplicate not held: {direct}")
if direct["sec1"] != ("AUTO", "rules"): fail("protected item must keep the rule result")
os.environ.pop("MEMTHENA_S1_THRESHOLD")
if rp._s1_cautious(items["new1"], "PARK", "unverifiable", rp.Project(proj)) != ("PARK", "unverifiable"): fail("non-AUTO tier changed")
if any("password" in s for s in Probe.seen): fail("protected item reached the model")
print("system-one-self-check: plan", base, "->", withm)
# Opt-in default: no env, no model.
os.environ.pop("MEMTHENA_S1"); rp._S1.clear()
if rp._s1_spec() != "": fail("System One must be off by default")
# ONNX 32m int8 when its runtime is present: acting keep/dup/rel.
os.environ.pop("MEMTHENA_S1_BACKEND")
if s1.bundled_spec().startswith("onnx:"):
    m = s1.load_predictor("bundled")
    if s1.acting(m) != {"keep", "dup", "rel"}: fail("32m acting heads wrong")
    r = s1.decide(req, m); p0, p1 = r["answers"]["relevance_0"]["noul"], r["answers"]["relevance_1"]["noul"]
    print(f"system-one-self-check: 32m int8 relevance ferry={p0} kernel={p1}")
else:
    print("system-one-self-check: 32m int8 runtime not installed; linear fallback checked")
PY
# Embedder: opt-in, bundled, produces a vector.
printf 'harbour ferry timetable\n' >"$fixture/q.txt"
out="$(LBEMBED_MODEL= python3 "$repo_root/models/lbembed.py" "$fixture/q.txt")"
grep -q '^dimensions: ' <<<"$out" || { echo 'system-one-self-check: embedder produced no vector' >&2; exit 1; }
# decide-serve: localhost server answers a Jev-style request (linear backend).
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1]); s.close()')"
MEMTHENA_S1_BACKEND=lin "$repo_root/bin/llm-brain" decide-serve bundled --port "$port" >/dev/null 2>&1 & srv=$!
trap 'kill "$srv" 2>/dev/null || true; rm -rf "$fixture"' EXIT
python3 - "$port" <<'PY'
import json, sys, time, urllib.request
for _ in range(50):
    try:
        req = urllib.request.Request(f"http://localhost:{sys.argv[1]}/v1/decide", data=json.dumps({"state": {"task": "ferry", "candidates": [{"title": "a", "excerpt": "b"}]}, "questions": {"triage": {"type": "choice", "criteria": ["answer", "other"]}, "relevance_0": {"type": "noul"}}}).encode(), headers={"Content-Type": "application/json"})
        r = json.load(urllib.request.urlopen(req, timeout=2)); break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit("system-one-self-check: decide-serve did not answer")
assert set(r["answers"]) == {"triage", "relevance_0"} and r["acting"] == ["dup"], r
PY
kill "$srv" 2>/dev/null || true
printf 'system-one-self-check: ok\n'
