#!/usr/bin/env bash
# Bulk folder stat (macOS getattrlistbulk) in the read-only record cache:
# one enumeration per folder replaces one lstat per record, with the same
# per-file freshness check.  On Linux the scanner is emulated (scandir +
# lstat) so the cache logic is exercised everywhere.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/memthena-bulk.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
XDG_CACHE_HOME="$fixture/cache" python3 - "$repo_root" "$fixture" <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import okf
REAL_SCAN = okf._bulk_scan
root = os.path.join(sys.argv[2], "proj"); claims = os.path.join(root, "okf", "claims")
os.makedirs(claims)
old = time.time() - 3600
def write(name, text):
    path = os.path.join(claims, name)
    with open(path, "w") as f: f.write(text)
    os.utime(path, (old, old))
for i in range(20):
    write(f"c{i:02d}.md", f"---\ntype: claim\ntitle: C{i}\n---\nBody {i}.\n")
os.symlink(os.path.join(claims, "c00.md"), os.path.join(claims, "link.md"))
names = sorted(os.listdir(claims))

scans = []
REAL_LSTAT = os.lstat
def emulated(folder):
    scans.append(folder)
    out = {}
    with os.scandir(folder) as it:
        for e in it:
            st = REAL_LSTAT(e.path)
            if e.is_file(follow_symlinks=False):
                out[e.name] = okf._BulkStat(st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, st.st_dev)
    return out

def run(bulk_env, scanner=emulated, trust=True, mutate=None):
    os.environ["MEMTHENA_BULK_STAT"] = bulk_env
    os.environ["MEMTHENA_NAS_TRUST_SECONDS"] = "0"
    okf._bulk_scan = scanner
    cache = okf.RecordCache(root, trust=trust)
    calls = [0]; real = os.lstat
    def counting(p, *a, **k):
        calls[0] += 1; return real(p, *a, **k)
    okf.os.lstat = counting
    result = {}
    try:
        for name in names:
            try:
                entry = cache.read(os.path.join(claims, name), "okf/claims/" + name)
                result[name] = (entry["sha"], entry.get("err"), sorted((entry.get("meta") or {}).items()))
            except Exception as exc:
                result[name] = ("error", type(exc).__name__)
    finally:
        okf.os.lstat = real
    cache.save()
    return result, calls[0]

def check(cond, msg):
    if not cond:
        print("bulk-stat-self-check:", msg, file=sys.stderr); sys.exit(1)

check(not okf.bulk_stat_enabled() if sys.platform != "darwin" and "MEMTHENA_BULK_STAT" not in os.environ else True, "bulk stat must default off outside macOS")
base, _ = run("0")                       # per-file lstat path, fills the cache
warm_off, lstat_off = run("0")
scans.clear(); warm_on, lstat_on = run("1")
check(warm_on == base == warm_off, "bulk results differ from per-file results")
check(scans == [claims], f"expected one scan of the claims folder, got {scans}")
check(lstat_on < lstat_off, f"bulk path did not save lstat calls ({lstat_on} vs {lstat_off})")
check(warm_on["link.md"][0] == "error", "a symlinked record must still be refused")
# Hand edit in place (same folder, no rename): seen at once through the per-file key.
path = os.path.join(claims, "c05.md")
with open(path, "r+") as f:
    f.seek(0, 2); f.write("Edited by hand.\n")
os.utime(path, (old + 60, old + 60))
edited, _ = run("1")
check(edited["c05.md"] != base["c05.md"], "bulk path missed an in-place hand edit")
check({k: v for k, v in edited.items() if k != "c05.md"} == {k: v for k, v in base.items() if k != "c05.md"}, "other records changed")
check(edited == run("0")[0], "bulk and per-file disagree after the edit")
# Unsupported or broken scanner: falls back to per-file lstat, same results.
fallback, lstat_fb = run("1", scanner=lambda folder: None)
check(fallback == edited and lstat_fb >= lstat_off, "fallback with no bulk support is wrong")
# Write-path caches (trust=False) never use bulk stat.
scans.clear(); run("1", trust=False)
check(scans == [], "a non read-only cache used bulk stat")
# On macOS the real getattrlistbulk scanner must agree with lstat exactly.
if sys.platform == "darwin":
    real = REAL_SCAN(claims)
    check(real is not None, "getattrlistbulk unsupported on this folder")
    want = emulated(claims)
    check({k: okf.RecordCache.stat_key(v) for k, v in real.items()} == {k: okf.RecordCache.stat_key(v) for k, v in want.items()}, "getattrlistbulk disagrees with lstat")
else:
    check(REAL_SCAN(claims) is None, "the real scanner must report unsupported outside macOS")
print("bulk-stat-self-check: ok")
PY
