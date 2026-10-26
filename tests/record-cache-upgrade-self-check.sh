#!/usr/bin/env bash
# Memthena NAS gap: after an upgrade (new code fingerprint) the local record
# cache keeps raw bytes + sha (pure functions of the file) and drops parsed
# fields, so the first run does not re-read every record over the network;
# a changed file is still re-read; search output is unchanged.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-cache-upgrade.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
python3 - "$repo_root" "$fixture" <<'PY'
import os, pickle, sys, time
repo, fx = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "lib"))
import okf
def fail(m): print("record-cache-upgrade-self-check:", m, file=sys.stderr); sys.exit(1)
root = os.path.join(fx, "p"); os.makedirs(os.path.join(root, "okf", "claims"))
for i in range(5):
    with open(os.path.join(root, "okf", "claims", f"c{i}.md"), "w") as f:
        f.write(f"---\ntype: Claim\ntitle: C{i}\n---\n# C{i}\n\nBody {i}.\n")
old = time.time() - 10
for name in os.listdir(os.path.join(root, "okf", "claims")):
    os.utime(os.path.join(root, "okf", "claims", name), (old, old))
c = okf.RecordCache(root)
for i in range(5):
    c.read(os.path.join(root, "okf", "claims", f"c{i}.md"), f"okf/claims/c{i}.md")
c.save()
data = pickle.load(open(c.path, "rb")); data["code"] = "older-code"; pickle.dump(data, open(c.path, "wb"))
c2 = okf.RecordCache(root)
if len(c2.entries) != 5 or any("meta" in e for e in c2.entries.values()): fail("upgrade must keep raw entries and drop parsed fields")
real_open = os.open
def no_open(*a, **k): raise AssertionError("record re-read after upgrade")
os.open = no_open
try:
    e = c2.read(os.path.join(root, "okf", "claims", "c1.md"), "okf/claims/c1.md", need_meta=True)
finally:
    os.open = real_open
if e["meta"].get("title") != "C1": fail("parsed fields not rebuilt from cached bytes")
with open(os.path.join(root, "okf", "claims", "c2.md"), "w") as f: f.write("---\ntype: Claim\ntitle: Changed\n---\n# Changed\n\nNew.\n")
e = c2.read(os.path.join(root, "okf", "claims", "c2.md"), "okf/claims/c2.md")
if e["meta"].get("title") != "Changed": fail("changed file not re-read")
print("record-cache-upgrade-self-check: ok")
PY
