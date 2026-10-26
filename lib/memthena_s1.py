#!/usr/bin/env python3
"""Memthena System One runtime (opt-in). Jev-style typed decisions; protection rules first; fails open to today's behaviour.
Backends: ONNX (onnxruntime + tokenizers) or the pure-stdlib linear model (.s1lin).
  python3 memthena_s1.py serve [MODEL_SPEC|bundled] [--port 8790]   # localhost only; point Hermes laya_url at http://localhost:8790/v1/decide
  MODEL_SPEC = onnx:TAG:DIR:FILE.onnx  |  lin:TAG:FILE.s1lin  |  bundled (the optional 32m int8 when installed and onnxruntime+tokenizers import, else the linear model)
Acting heads (passed the pre-registered m13/m13b tests): ONNX 32m int8 = keep, dup, rel; linear = dup only.
kind and triage are advisory only: answered, never used to change an outcome.
Licence: Apache-2.0. Inspired by Jev (TypeSafe AI) and open Jev-style models (Laya, jevos, Tiny-Jev); no code or weights from them."""
import json, math, os, re, struct, sys, time, zlib
HEADS = ["keep", "kind", "dup", "rel", "triage"]
KINDS = ["claim", "procedure", "reference", "none"]
TRIAGE = ["answer", "procedure", "reference", "current_state", "other"]
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
    import review_policy as _rp
    SECRET, REDACTED, PERSONAL, HOLD_ANY = _rp.SECRET, _rp.REDACTED, _rp.PERSONAL_TOPIC, _rp.HOLD_ANYWHERE
except Exception:  # identical copies of the 0.11 patterns
    SECRET = re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----|(?<![A-Za-z0-9_])sk-(proj-)?[A-Za-z0-9_-]{16,}|(?<![A-Za-z0-9_])AKIA[0-9A-Z]{16}|(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,}|(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}|(api[_-]?key|secret|password|token)[ \t\f\v]*[:=][ \t\f\v]*"?[A-Za-z0-9_./+=-]{16,}', re.I)
    REDACTED = re.compile(r'\[redacted sha256:[0-9a-f]{12}\]')
    PERSONAL = re.compile(r'health|clinical|medical|medication|privacy|private life|legal|lawyer|finance|financial|payment|tax\b|bank')
    HOLD_ANY = re.compile(r'security|authenticat|credential|secret|password|private key|\bssh\b')
SENS_BLOCK = re.compile(r"^(brain_)?sensitivity:\s*\"?(restricted|private|owner-only|secret)", re.M)
SECRET_META = re.compile(r"secret|credential|token|password|passwd|api[ _-]?key|apikey|private[ _-]?key|ssh|oauth|vault[ _-]?key", re.I)
SECRET_BODY = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-(proj-)?[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|(api[_-]?key|secret|password|token)\s*[:=]\s*\"?[A-Za-z0-9_./+=-]{16,}", re.I)
META_LINE = re.compile(r"^(title|tags|brain_tags|brain_labels|brain_topic|brain_topic_labels):(.*)$", re.M)
def _malformed(text):
    if not text.startswith("---"): return False   # plain state text (Hermes candidates) has no frontmatter
    m = re.match(r"---\n(.*?)\n---(\n|$)", text, re.S)
    if not m: return True
    keys = re.findall(r"^([A-Za-z_][A-Za-z0-9_]*):", m.group(1), re.M)
    return len(keys) != len(set(keys))
def protected(text):
    """True = never sent to any model. Superset of the labeller's Gate 0: secret (scanner, m12 body/metadata patterns, redaction),
    owner-only sensitivity, personal topics, security words, malformed or duplicate-key frontmatter."""
    low = text.lower()
    return bool(SECRET.search(text) or SECRET_BODY.search(text) or REDACTED.search(text) or SENS_BLOCK.search(text) or PERSONAL.search(low) or HOLD_ANY.search(low)
                or re.search(r"^brain_review_kind:\s*redaction", text, re.M) or any(SECRET_META.search(v) for _, v in META_LINE.findall(text)) or _malformed(text))
def _sig(x): return 1 / (1 + math.exp(-max(-60, min(60, x))))
def _soft(z):
    m = max(z); e = [math.exp(v - m) for v in z]; s = sum(e); return [v / s for v in e]
class OnnxPred:
    def __init__(self, tag, d, f):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        o = ort.SessionOptions(); o.intra_op_num_threads = int(os.environ.get("MEMTHENA_S1_THREADS", "1")); o.inter_op_num_threads = 1
        self.sess = ort.InferenceSession(os.path.join(d, f), o, providers=["CPUExecutionProvider"])
        meta = json.load(open(os.path.join(d, "meta.json"))); self.temps = meta["temps"]; ml = meta.get("maxlen", 256)
        self.tok = Tokenizer.from_file(os.path.join(d, "tokenizer", "tokenizer.json")); self.tok.enable_truncation(ml)
        self.tag, self.size = tag, os.path.getsize(os.path.join(d, f))
    def logits(self, head, pairs):
        import numpy as np
        out = []
        for i in range(0, len(pairs), 32):
            ch = pairs[i:i + 32]
            encs = [self.tok.encode(a, b) if b is not None else self.tok.encode(a) for a, b in ch]
            T = max(len(e.ids) for e in encs); ids = np.zeros((len(encs), T), np.int64); am = np.zeros((len(encs), T), np.int64)
            for j, e in enumerate(encs): ids[j, :len(e.ids)] = e.ids; am[j, :len(e.ids)] = 1
            r = self.sess.run([head], {"input_ids": ids, "attention_mask": am})[0]; out += r.tolist()
        return out
class LinPred:
    """Hashed word uni/bigram linear model. Pure stdlib (runs on a Pi Zero)."""
    def __init__(self, tag, f):
        data = open(f, "rb").read(); hl = struct.unpack_from("<I", data, 6)[0]; self.hdr = json.loads(data[10:10 + hl]); p = 10 + hl
        self.D = self.hdr["dim"]; self.cols = self.hdr["cols"]; self.temps = self.hdr["temps"]; C = sum(self.cols.values())
        self.scale = struct.unpack_from(f"<{C}f", data, p); p += 4 * C; self.bias = struct.unpack_from(f"<{C}f", data, p); p += 4 * C
        self.W = memoryview(data)[p:p + C * self.D].cast("b"); self.C = C; self.tag, self.size = tag, len(data)
        self.off = {}; o = 0
        for h in HEADS: self.off[h] = o; o += self.cols[h]
    def logits(self, head, pairs):
        o, k = self.off[head], self.cols[head]; out = []
        for a, b in pairs:
            z = [self.bias[o + c] for c in range(k)]
            for idx in lin_features(a, b, self.D):
                for c in range(k): z[c] += self.W[(o + c) * self.D + idx] * self.scale[o + c]
            out.append(z)
        return out
_TOK = re.compile(r"[a-z0-9]+")
def lin_features(a, b, D):
    ta = _TOK.findall(a.lower()); f = ["a:" + t for t in ta] + ["a2:" + x + "_" + y for x, y in zip(ta, ta[1:])] + ["bias"]
    if b is not None:
        tb = _TOK.findall(b.lower()); sa, sb = set(ta), set(tb); f += ["b:" + t for t in tb] + ["s:" + t for t in sa & sb]
        j = len(sa & sb) / max(1, len(sa | sb)); f += [f"jac:{int(j * 10)}"]
        na, nb = set(re.findall(r"\d+", a)), set(re.findall(r"\d+", b)); f += ["numeq" if na == nb else "numdiff"]
    return sorted({zlib.crc32(x.encode()) % D for x in f})
ACTING = {"onnx": frozenset({"keep", "dup", "rel"}), "lin": frozenset({"dup"})}
ADVISORY = ("kind", "triage")
_MODELS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models")
OPTIONAL_32M = "memthena-s1-32m-int8"
def user_models_dir():
    """Per-machine folder for optional models (`llm-brain models install system-one-32m`); never in a vault."""
    return os.environ.get("MEMTHENA_S1_MODELS_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"), "llm-brain", "models")
def installed_32m(models_dir=None):
    """Folder of the installed optional 32m model, or "" when it is absent or incomplete."""
    for d in ([models_dir] if models_dir else [user_models_dir(), _MODELS]):
        cand = os.path.join(os.path.abspath(d), OPTIONAL_32M)
        if all(os.path.isfile(os.path.join(cand, f)) for f in ("memthena-s1-32m.int8.onnx", "meta.json", os.path.join("tokenizer", "tokenizer.json"))):
            return cand
    return ""
def lin_spec():
    lin = os.path.join(os.path.abspath(_MODELS), "memthena-s1-lin", "memthena-s1-lin.s1lin")
    return ("lin:memthena-s1-lin:" + lin) if os.path.isfile(lin) else ""
def bundled_spec(models_dir=None):
    """The optional 32m model when it is installed and onnxruntime + tokenizers import; otherwise the
    linear model that ships in the base package (duplicate head only); "" when neither is usable (fail-open)."""
    onnx_dir = installed_32m(models_dir)
    if onnx_dir and os.environ.get("MEMTHENA_S1_BACKEND", "") != "lin":
        try:
            import onnxruntime, tokenizers  # noqa: F401
            return "onnx:" + OPTIONAL_32M + ":" + onnx_dir + ":memthena-s1-32m.int8.onnx"
        except Exception:
            pass
    return lin_spec()
def acting(pred):
    return ACTING["onnx"] if isinstance(pred, OnnxPred) else ACTING["lin"]
def load_predictor(spec):
    if spec in ("bundled", "1"):
        spec = bundled_spec()
        if not spec: raise FileNotFoundError("no bundled System One model")
        if spec.startswith("onnx:"):
            try:
                return load_predictor(spec)
            except Exception:  # a broken optional install falls back to the base linear model
                spec = lin_spec()
                if not spec: raise
    k, rest = spec.split(":", 1)
    if k == "onnx": tag, d, f = rest.split(":"); return OnnxPred(tag, d, f)
    tag, f = rest.split(":"); return LinPred(tag, f)
def _p(pred, head, pairs):
    z = pred.logits(head, pairs); T = pred.temps.get(head, 1.0)
    return [_sig(v[0] / T) for v in z] if head in ("keep", "dup", "rel") else [_soft([x / T for x in v]) for v in z]
def review_hook_decision(raw_text, pred, threshold=0.90, neighbours=None):
    """Used by review_policy (opt-in). Returns None (no model opinion) for protected items or on any error.
    Otherwise keep/dup probabilities for the acting heads only. The caller may only use it to make a tier MORE cautious.
    NEIGHBOURS: list of (id, title, body) canonical records already screened by protected()."""
    try:
        if protected(raw_text) or pred is None: return None
        lines = raw_text.split("\n")                     # same rule as review_policy.split_frontmatter/parse_header
        if not lines or lines[0] != "---" or "---" not in lines[1:]: return None
        seen = set()
        for line in lines[1:lines.index("---", 1)]:
            c = line.find(":")
            if c <= 0: continue
            k = line[:c]
            if k in seen and (k.startswith("brain_") or k in ("type", "title")): return None
            seen.add(k)
        m = re.match(r"---\n(.*?)\n---\n?(.*)", raw_text, re.S)
        meta = dict(re.findall(r"^([a-z_]+):\s*\"?(.*?)\"?\s*$", m.group(1), re.M)) if m else {}
        body = re.sub(r"^#.*$", "", m.group(2) if m else raw_text, count=1, flags=re.M).strip()
        txt = (f"[TYPE] {meta.get('type','')} [TITLE] {meta.get('title','')} [META] review={meta.get('brain_review_state','')} sens={meta.get('brain_sensitivity','')} "
               f"auth={meta.get('brain_source_authority','')} [BODY] {body[:600]}")
        heads = acting(pred); out = {"keep": None, "acts": False, "dup": None, "dup_acts": False, "dup_of": ""}
        if "keep" in heads:
            p = _p(pred, "keep", [(txt, None)])[0]
            out["keep"], out["acts"] = p, max(p, 1 - p) >= threshold
        if "dup" in heads and neighbours:
            rt = f"[TYPE] {meta.get('type','')} [TITLE] {meta.get('title','')} [BODY] {body[:600]}"
            ps = _p(pred, "dup", [(rt, f"[TITLE] {t} [BODY] {b[:400]}") for _, t, b in neighbours])
            i = max(range(len(ps)), key=ps.__getitem__)
            out["dup"], out["dup_acts"], out["dup_of"] = ps[i], ps[i] >= threshold, neighbours[i][0]
        return out
    except Exception:
        return None
_W = re.compile(r"[a-z0-9]{3,}")
def nearest(text, records, k=4, floor=0.2):
    """Up to K (id, title, body) records sharing the most words with TEXT (Jaccard >= FLOOR)."""
    a = set(_W.findall(text.lower())); scored = []
    if not a: return []
    for rid, title, body in records:
        b = set(_W.findall((title + " " + body).lower()))
        j = len(a & b) / max(1, len(a | b))
        if j >= floor: scored.append((j, rid, title, body))
    scored.sort(key=lambda r: (-r[0], r[1]))
    return [(rid, t, b) for _, rid, t, b in scored[:k]]
def decide(req, pred):
    """Jev-style request -> response (shape accepted by the Hermes plugin's _validate_laya_answers)."""
    t0 = time.perf_counter(); st = req.get("state") or {}; qs = req.get("questions") or {}; task = str(st.get("task") or "")[:384]
    cands = st.get("candidates") or []; answers = {}
    for name, q in qs.items():
        typ = q.get("type")
        if name.startswith("relevance_"):
            i = int(name.split("_")[1]); c = cands[i] if i < len(cands) else {}
            blob = json.dumps(c)
            if "rel" not in acting(pred): p = 1.0   # not an acting head here: neutral, so Hermes keeps every candidate
            else: p = 0.0 if protected(blob) else _p(pred, "rel", [(f"[TASK] {task}", f"[TITLE] {c.get('title','')} [BODY] {str(c.get('excerpt',''))[:400]}")])[0]
            answers[name] = {"type": "noul", "noul": round(p, 4), "probability": round(p, 4)}
        elif name == "triage" or (typ == "choice" and name in ("kind",)):
            crit = q.get("criteria") or TRIAGE
            if name == "triage":
                P = _p(pred, "triage", [(f"[TASK] {task}", None)])[0]; pm = {c: (P[TRIAGE.index(c)] if c in TRIAGE else 0.0) for c in crit}
            else:
                r = st.get("record") or {}; P = _p(pred, "kind", [(f"[TYPE] {r.get('type','')} [TITLE] {r.get('title','')} [BODY] {str(r.get('excerpt',''))[:600]}", None)])[0]
                pm = {c: (P[KINDS.index(c)] if c in KINDS else 0.0) for c in crit}
            s = sum(pm.values()) or 1.0; pm = {k: round(v / s, 4) for k, v in pm.items()}; best = max(pm, key=pm.get)
            answers[name] = {"type": "choice", "choice": best, "probabilities": pm, "confidence": pm[best]}
        elif name in ("keep",) or name.startswith("duplicate_of_neighbour"):
            r = st.get("record") or {}; rt = f"[TYPE] {r.get('type','')} [TITLE] {r.get('title','')} [BODY] {str(r.get('excerpt',''))[:600]}"
            if protected(json.dumps(r)): p = 0.0
            elif name == "keep": p = _p(pred, "keep", [(rt, None)])[0]
            else:
                i = int(name.rsplit("_", 1)[1]); n = (st.get("neighbours") or [{}])[i]
                p = _p(pred, "dup", [(rt, f"[TITLE] {n.get('title','')} [BODY] {str(n.get('excerpt',''))[:400]}")])[0]
            answers[name] = {"type": "noul", "noul": round(p, 4), "probability": round(p, 4)}
    return {"answers": answers, "model": req.get("model") or pred.tag, "acting": sorted(acting(pred)), "advisory": list(ADVISORY), "latency_ms": round((time.perf_counter() - t0) * 1000, 1)}
def serve(spec, port):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    pred = load_predictor(spec)
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                n = min(int(self.headers.get("Content-Length", "0")), 2 * 1024 * 1024); body = json.dumps(decide(json.loads(self.rfile.read(n)), pred)).encode(); code = 200
            except Exception as e: body = json.dumps({"error": "bad request"}).encode(); code = 400
            self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *a): pass
    ThreadingHTTPServer(("localhost", port), H).serve_forever()
if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "status":
        spec = bundled_spec(); d = installed_32m()
        print(f"system_one_32m={'installed' if d else 'absent'} system_one_linear={'present' if lin_spec() else 'absent'} active={(spec.split(':')[1] if spec else 'none')}")
        raise SystemExit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "serve":
        serve(sys.argv[2] if not sys.argv[2].startswith("--") else "bundled", int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8790)
    else: print(__doc__)
