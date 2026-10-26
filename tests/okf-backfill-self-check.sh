#!/usr/bin/env bash
# 0.12 `migrate okf-backfill`: --check is read-only; --apply only adds
# (one description: line per record, generated folder index.md files);
# restricted records stay byte-identical and out of index text; index build
# keeps generated indexes fresh; --undo restores the okf/ tree byte for byte.
# OKF_BACKFILL_N (default 240) sets the synthetic size; the 1k/5k runs use it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-okf-backfill.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
n="${OKF_BACKFILL_N:-240}"
vault="$fixture/vault"; workspace="$fixture/ws"; mkdir -p "$workspace"
project_id="proj_backfill"
fail() { printf 'okf-backfill-self-check: %s\n' "$*" >&2; exit 1; }
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
secret_value="$(python3 -c 'print("Q7x"+"Z"*20)')"

python3 - "$project" "$n" "$secret_value" <<'PY'
import os, random, sys
project, n, secret = sys.argv[1], int(sys.argv[2]), sys.argv[3]
random.seed(7)
words = "harbour ferry tide timetable deploy kernel cache lock index search doctor capture vault share latency backup".split()
for d in ("claims", "procedures", "references", "topics/ops", "topics/ops/deep"):
    os.makedirs(f"{project}/okf/{d}", exist_ok=True)
def rec(path, extra="", body=None, nl="\n", title=None):
    title = title or os.path.basename(path)[:-3].replace("-", " ").title()
    body = body if body is not None else " ".join(random.choice(words) for _ in range(40)) + ". Second sentence here."
    head = ["---", "type: Claim", f"title: {title}", "brain_review_state: approved", "brain_sensitivity: internal", "brain_schema_version: 3"]
    head += [line for line in extra.split("\n") if line]
    with open(f"{project}/okf/{path}", "w", newline="") as f:
        f.write(nl.join(head + ["---", f"# {title}", "", body, ""]))
for i in range(n):
    folder = ("claims", "procedures", "references", "topics/ops", "topics/ops/deep")[i % 5]
    rec(f"{folder}/r{i:05d}.md")
rec("claims/secret-one.md", body=f"Rotate it. password: \"{secret}\" was leaked.", title="Secret Holder Title")
rec("claims/private-one.md", extra="brain_sensitivity_note: x", title="Private Plan")
with open(f"{project}/okf/claims/private-one.md") as f: t = f.read()
with open(f"{project}/okf/claims/private-one.md", "w") as f: f.write(t.replace("brain_sensitivity: internal", "brain_sensitivity: private"))
rec("claims/scoped-one.md", extra="brain_principal: alice", title="Alice Only")
rec("claims/described.md", extra='description: "Already described record."')
rec("claims/crlf-one.md", nl="\r\n")
rec("claims/empty-body.md", body="")
with open(f"{project}/okf/references/index.md", "w") as f: f.write("# References\n\nHand-written index kept by the backfill.\n")
PY

snap() { # okf/ tree: path, sha256 and mode of every file
  python3 - "$project/okf" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for base, dirs, files in sorted(os.walk(root)):
    dirs.sort()
    for name in sorted(files):
        p = os.path.join(base, name)
        st = os.lstat(p)
        print(os.path.relpath(p, root), oct(st.st_mode), hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}
full_snap() { (cd "$project" && find . -type f ! -path './.locks/*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null || find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }

"$cli" --root "$vault" lint >/dev/null || fail "fixture lint failed before backfill"
"$cli" --root "$vault" index build "$project_id" >/dev/null
before="$(snap)"; before_full="$(full_snap)"

# 1. --check (default) is read-only and reports counts and samples.
out="$("$cli" --root "$vault" migrate okf-backfill --samples 2)"
[ "$(full_snap)" = "$before_full" ] || fail "--check changed the vault"
printf '%s\n' "$out" | grep -q "okf_backfill=check project=$project_id records=$((n + 7)) add=$((n + 2)) has_description=1 restricted=3 no_lead=1" || fail "unexpected check counts: $out"
printf '%s\n' "$out" | grep -q 'folders=6 index_create=5 .*index_user_kept=1' || fail "unexpected index plan: $out"
[ "$(printf '%s\n' "$out" | grep -c '^okf_backfill:sample ')" = 2 ] || fail "samples missing"
"$cli" --root "$vault" migrate okf-backfill --samples 0 | grep -q 'okf_backfill:sample' && fail "--samples 0 printed samples"
printf '%s\n' "$out" | grep -q "$secret_value" && fail "check printed a secret"

# 2. A newer writer.format refuses --apply (format rules respected).
cp "$vault/writer.format" "$fixture/wf" 2>/dev/null || true
printf 'format_level=9\nwriter_version=9.0.0\n' >"$vault/writer.format"
if "$cli" --root "$vault" migrate okf-backfill --apply >/dev/null 2>&1; then fail "apply ignored a newer writer.format"; fi
[ "$(snap)" = "$before" ] || fail "refused apply changed okf/"
if [ -f "$fixture/wf" ]; then cp "$fixture/wf" "$vault/writer.format"; else rm -f "$vault/writer.format"; fi

# 3. --apply: additive only.
out="$("$cli" --root "$vault" migrate okf-backfill --apply)"
run_id="$(printf '%s\n' "$out" | sed -n 's/^okf_backfill_id=\([^ ]*\).*/\1/p')"
[ -n "$run_id" ] || fail "no run id: $out"
printf '%s\n' "$out" | grep -q "descriptions=$((n + 2)) skipped_changed=0 index_created=5" || fail "unexpected apply: $out"
[ ! -d "$vault/.locks/project-$project_id.lock" ] || fail "lock left behind"
grep -q "	okf-backfill-apply	$project_id	$run_id	" "$project/audit.v2.tsv" || fail "apply not audited"
python3 - "$project" "$secret_value" <<'PY' || exit 1
import hashlib, os, sys, yaml
project, secret = sys.argv[1], sys.argv[2]
for base, _, files in os.walk(f"{project}/okf"):
    for name in files:
        if name in ("index.md", "log.md"): continue
        raw = open(os.path.join(base, name), "rb").read()
        assert raw.count(b"\ndescription: ") <= 1, name
        assert raw.startswith(b"---"), name
for name in ("secret-one", "private-one", "scoped-one", "empty-body"):
    assert b"description:" not in open(f"{project}/okf/claims/{name}.md", "rb").read(), name
crlf = open(f"{project}/okf/claims/crlf-one.md", "rb").read()
assert b"description: " in crlf and b"\n" not in crlf.replace(b"\r\n", b""), "crlf broken"
for base, _, files in os.walk(f"{project}/okf"):
    if "index.md" in files and base != f"{project}/okf":
        text = open(os.path.join(base, "index.md")).read()
        for bad in (secret, "Secret Holder", "Private Plan", "Alice Only", "Rotate it"):
            assert bad not in text, (base, bad)
claims = open(f"{project}/okf/claims/index.md").read()
assert claims.count("Restricted record") == 3 and "(secret-one.md)" in claims and "Already described record." in claims
assert "## Folders" in open(f"{project}/okf/topics/index.md").read()
assert open(f"{project}/okf/references/index.md").read().startswith("# References\n\nHand-written"), "user index rewritten"
PY
okf_py="$repo_root/lib/okf.py"
python3 "$okf_py" validate-bundle "$project/okf" >/dev/null || fail "OKF bundle invalid after apply"
"$cli" --root "$vault" lint >/dev/null || fail "lint failed after apply"
# Bodies untouched: removing exactly the inserted line restores each before_sha.
python3 - "$project" "$run_id" <<'PY' || exit 1
import hashlib, json, sys
project, run = sys.argv[1], sys.argv[2]
m = json.load(open(f"{project}/migrations/okf-backfill/{run}/manifest.json"))
for e in m["edits"]:
    raw = open(f"{project}/{e['rel']}", "rb").read()
    ins = e["insert"].encode()
    assert raw[e["offset"]:e["offset"] + len(ins)] == ins and ins.startswith(b"description: ")
    assert hashlib.sha256(raw[:e["offset"]] + raw[e["offset"] + len(ins):]).hexdigest() == e["before_sha"]
PY

# 4. Freshness: index build regenerates generated indexes, never user ones.
"$cli" --root "$vault" index build "$project_id" >/dev/null
cp "$project/okf/claims/r00000.md" "$project/okf/claims/zz-new.md"
sed -i.bak 's/^title: .*/title: Fresh Late Record/' "$project/okf/claims/zz-new.md" && rm -f "$project/okf/claims/zz-new.md.bak"
"$cli" --root "$vault" index build "$project_id" >/dev/null
grep -q 'Fresh Late Record' "$project/okf/claims/index.md" || fail "index build did not refresh index.md"
grep -q 'Fresh Late Record' "$project/okf/references/index.md" && fail "user index touched"
rm -f "$project/okf/claims/zz-new.md"

# 5. Undo refuses when a backfilled record was edited later, changing nothing.
printf 'later edit\n' >>"$project/okf/claims/r00000.md"
mid="$(snap)"
if "$cli" --root "$vault" migrate okf-backfill --undo "$run_id" >/dev/null 2>&1; then fail "undo ignored a later edit"; fi
[ "$(snap)" = "$mid" ] || fail "refused undo changed okf/"
python3 - "$project/okf/claims/r00000.md" <<'PY'
import sys; p = sys.argv[1]; b = open(p, "rb").read(); open(p, "wb").write(b[: -len(b"later edit\n")])
PY

# 6. Undo restores okf/ byte for byte (content and mode).
"$cli" --root "$vault" migrate okf-backfill --undo "$run_id" | grep -q "okf_backfill=undone id=$run_id restored=$((n + 2))" || fail "undo failed"
[ "$(snap)" = "$before" ] || { diff <(printf '%s\n' "$before") <(snap) | head >&2; fail "undo is not byte-exact"; }
[ ! -f "$project/migrations/okf-backfill/active" ] || fail "active flag left after undo"
"$cli" --root "$vault" index build "$project_id" >/dev/null
[ "$(snap)" = "$before" ] || fail "index build recreated indexes after undo"
"$cli" --root "$vault" lint >/dev/null || fail "lint failed after undo"
"$cli" --root "$vault" migrate okf-backfill --undo "$run_id" | grep -q 'already-undone' || fail "second undo not idempotent"
printf 'okf-backfill-self-check: ok records=%s run=%s\n' "$((n + 7))" "$run_id"
