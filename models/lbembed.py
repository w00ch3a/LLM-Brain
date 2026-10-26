#!/usr/bin/env python3
"""lbembed: LLM-Brain's own static embedder. Pure Python standard library (no numpy), so it
runs anywhere Python 3.8+ runs, including a Raspberry Pi Zero 2 W.

Usage (as an LLM-Brain --embedder / --query-embedder executable):
    lbembed FILE            -> prints "model: ...", "dimensions: N", "vector: ..." for FILE's text
Env:
    LBEMBED_MODEL   path to an lbembed .bin (default: lbembed-v2-int4.bin next to this script, the model Memthena ships)
File formats: header version 1 = int8 rows (v1 and v2 models); version 2 adds "quant": "int4" (packed 4-bit rows).
"""
import json, math, os, struct, sys, unicodedata

class LBEmbed:
    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        if not data.startswith(b"LBEMB1\n"):
            raise ValueError("not an lbembed file")
        hl, vl = struct.unpack_from("<II", data, 7)
        p = 15
        self.hdr = json.loads(data[p:p + hl]); p += hl
        vocab = data[p:p + vl].decode("utf-8").split("\n"); p += vl
        self.V, self.D = self.hdr["vocab_size"], self.hdr["dim"]
        self.vocab = {t: i for i, t in enumerate(vocab)}
        self.scale = struct.unpack_from(f"<{self.V}e", data, p); p += 2 * self.V
        self.quant = self.hdr.get("quant", "int8")
        if self.quant == "int8":
            self.rows = memoryview(data)[p:p + self.V * self.D].cast("b")
        elif self.quant == "int4":   # format version 2: two 4-bit values per byte (low nibble first), value = nibble - 8
            self.rb = (self.D + 1) // 2; self.rows = memoryview(data)[p:p + self.V * self.rb]
        else:
            raise ValueError("unsupported lbembed quantisation: " + str(self.quant))
        self.unk = self.vocab.get(self.hdr.get("unk", "[UNK]"), 1)
        self.maxtok = self.hdr.get("max_tokens", 512)

    # --- BERT-style basic tokenisation (matches HF BertWordPieceTokenizer, uncased) ---
    @staticmethod
    def _is_punct(ch):
        cp = ord(ch)
        if 33 <= cp <= 47 or 58 <= cp <= 64 or 91 <= cp <= 96 or 123 <= cp <= 126: return True
        return unicodedata.category(ch).startswith("P")

    @staticmethod
    def _is_cjk(cp):
        return (0x4E00 <= cp <= 0x9FFF or 0x3400 <= cp <= 0x4DBF or 0x20000 <= cp <= 0x2A6DF or 0x2A700 <= cp <= 0x2B73F
                or 0x2B740 <= cp <= 0x2B81F or 0x2B820 <= cp <= 0x2CEAF or 0xF900 <= cp <= 0xFAFF or 0x2F800 <= cp <= 0x2FA1F)

    def basic(self, text):
        out = []
        for ch in text:
            cp = ord(ch)
            if cp == 0 or cp == 0xFFFD or (unicodedata.category(ch) in ("Cc", "Cf") and ch not in "\t\n\r"): continue
            if ch in "\t\n\r" or unicodedata.category(ch) == "Zs": out.append(" "); continue
            if self._is_cjk(cp): out.append(f" {ch} "); continue
            out.append(ch)
        text = "".join(out).lower()
        text = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")
        toks = []
        for w in text.split():
            cur = ""
            for ch in w:
                if self._is_punct(ch):
                    if cur: toks.append(cur); cur = ""
                    toks.append(ch)
                else: cur += ch
            if cur: toks.append(cur)
        return toks

    def wordpiece(self, word):
        if len(word) > 100: return [self.unk]
        ids, start = [], 0
        while start < len(word):
            end, cur = len(word), None
            while start < end:
                sub = word[start:end] if start == 0 else "##" + word[start:end]
                if sub in self.vocab: cur = self.vocab[sub]; break
                end -= 1
            if cur is None: return [self.unk]
            ids.append(cur); start = end
        return ids

    def token_ids(self, text):
        ids = []
        for w in self.basic(text):
            ids.extend(self.wordpiece(w))
            if len(ids) >= self.maxtok: break
        return [i for i in ids[:self.maxtok] if i > 4]

    def row(self, i):
        """Dequantised row i as a list of floats."""
        s = self.scale[i]
        if self.quant == "int8":
            return [x * s for x in self.rows[i * self.D:(i + 1) * self.D]]
        out = []
        for b in self.rows[i * self.rb:(i + 1) * self.rb]:
            out.append(((b & 15) - 8) * s); out.append(((b >> 4) - 8) * s)
        return out[:self.D]

    def embed(self, text):
        D, rows, sc = self.D, self.rows, self.scale
        acc = [0.0] * D
        if self.quant != "int8":
            for i in self.token_ids(text):
                for k, x in enumerate(self.row(i)): acc[k] += x
        else:
          for i in self.token_ids(text):
            s = sc[i]; base = i * D; r = rows[base:base + D]
            for k in range(D): acc[k] += r[k] * s
        n = math.sqrt(sum(x * x for x in acc)) or 1.0
        return [x / n for x in acc]

def strip_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            nl = text.find("\n", end + 4)
            return text[nl + 1:] if nl != -1 else ""
    return text

def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write("usage: lbembed FILE\n"); return 64
    model = os.environ.get("LBEMBED_MODEL") or os.path.join(os.path.dirname(os.path.realpath(__file__)), "lbembed-v2-int4.bin")
    m = LBEmbed(model)
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        text = strip_frontmatter(f.read())
    v = m.embed(text)
    sys.stdout.write(f"model: {m.hdr.get('model', 'lbembed-v1')}\ndimensions: {m.D}\nvector: " + " ".join(f"{x:.5f}" for x in v) + "\n")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
