#!/usr/bin/env bash
# Upgrade an installed previous release (default v0.7.6) to this checkout via
# the documented `upgrade check` / `upgrade apply` path, with a populated
# synthetic vault, then prove the data is intact and the new commands, MCP and
# hook work against the untouched vault.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
previous_ref="${LLM_BRAIN_PREVIOUS_REF:-v0.7.6}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-upgrade-previous.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'upgrade-from-previous self-check: %s\n' "$*" >&2; exit 1; }

if ! git -C "$repo_root" rev-parse --verify -q "$previous_ref^{commit}" >/dev/null; then
  printf 'upgrade-from-previous self-check: skipped (%s not available in this checkout)\n' "$previous_ref"
  exit 0
fi
old_src="$fixture/previous"
mkdir -p "$old_src"
git -C "$repo_root" archive "$previous_ref" | tar -x -C "$old_src"
previous_version="$(tr -d '[:space:]' <"$old_src/VERSION")"
[ "$previous_version" != "$version" ] || fail 'previous ref has the current VERSION'

home="$fixture/home"; data="$fixture/data"; state="$fixture/state"; vault="$fixture/vault"; workspace="$fixture/workspace"
mkdir -p "$home" "$data" "$state" "$workspace"
real_python="$(command -v python3)"
yaml_parent="$("$real_python" -c 'import os, yaml; print(os.path.dirname(os.path.dirname(yaml.__file__)))')"
for v in "$previous_version" "$version"; do
  wrapper="$data/llm-brain/runtimes/$v/bin/python"
  mkdir -p "$(dirname "$wrapper")"
  printf '#!/bin/sh\nexport PYTHONPATH="%s${PYTHONPATH:+:$PYTHONPATH}"\nexec "%s" "$@"\n' "$yaml_parent" "$real_python" >"$wrapper"
  chmod +x "$wrapper"
done
env_run() {
  HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" LLM_BRAIN_ROOT="$vault" \
  LLM_BRAIN_BACKUP_ROOT="$fixture/backups" LLM_BRAIN_STANDALONE_ROOT="$home/standalone" \
  LLM_BRAIN_UPGRADE_SOURCE="$repo_root" "$@"
}

# 1. Install the previous release as the active standalone launcher.
install_dir="$home/standalone/$previous_version"
mkdir -p "$install_dir/lib" "$home/.local/bin"
install -m 0755 "$old_src/bin/llm-brain" "$install_dir/llm-brain"
install -m 0644 "$old_src/lib/okf.py" "$install_dir/lib/okf.py"
[ ! -f "$old_src/lib/replication.py" ] || install -m 0644 "$old_src/lib/replication.py" "$install_dir/lib/replication.py"
install -m 0644 "$old_src/VERSION" "$old_src/requirements-okf.lock" "$install_dir/"
ln -s "$install_dir/llm-brain" "$home/.local/bin/llm-brain"
old="$home/.local/bin/llm-brain"
[ "$(env_run "$old" --version)" = "$previous_version" ] || fail 'previous release did not install'

# 2. Populate a realistic synthetic vault with the previous release.
git -C "$workspace" init -q
project_id="proj_upgrade_previous"
env_run "$old" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
for n in 1 2 3; do
  {
    printf '%s\n' '---' 'type: Claim' "title: \"Deploy rule $n\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-01-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_schema_version: 3'
    [ "$n" != 3 ] || printf '%s\n' 'brain_principal: alex'
    printf '%s\n' '---' "# Deploy rule $n" '' "Deploy rule $n: releases ship on Tuesday after the checklist."
  } >"$project/okf/claims/deploy-$n.md"
done
printf 'Synthetic meeting note: the release checklist gained a smoke test.\n' >"$fixture/note.md"
env_run "$old" ingest-source "$project_id" "$fixture/note.md" >/dev/null
env_run "$old" search "$project_id" 'deploy rule' --receipt >/dev/null
pack="$(env_run "$old" pack build "$project_id" --task 'deploy rule checklist' --receipt | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
env_run "$old" feedback record "$project_id" --pack "${pack#"$project/"}" --usefulness useful >/dev/null
env_run "$old" index build "$project_id" >/dev/null
env_run "$old" maintenance run "$project_id" >/dev/null
[ -s "$project/audit/retrieval-receipts.jsonl" ] || fail 'previous release wrote no receipts'
[ -n "$(find "$project/review" -name '*.md' -print -quit)" ] || fail 'previous release wrote no review items'
canonical_digest() { (cd "$1" && find okf sources episodes review feedback audit -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | awk '{print $1}')"; done); }
before="$(canonical_digest "$project")"
snapshot_before="$fixture/before-upgrade"; cp -R "$project" "$snapshot_before"
# Upgrade re-stages every vault (backup + rollback tree).  Records must survive
# semantically: same files, same YAML values and bodies; the only permitted
# change is source-reconciliation bookkeeping on episodes.
compare_snapshots() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
from pathlib import Path
before, after = Path(sys.argv[1]), Path(sys.argv[2])
areas = ("okf", "sources", "episodes", "review", "feedback", "audit")
def files(root):
    return {p.relative_to(root).as_posix() for area in areas for p in (root / area).rglob("*") if p.is_file()}
def split(text):
    if text.startswith("---\n"):
        head, _, body = text[4:].partition("\n---\n")
        return yaml.safe_load(head) or {}, body
    return None, text
problems = []
b, a = files(before), files(after)
if b != a:
    problems.append(f"file set changed: added={sorted(a - b)} removed={sorted(b - a)}")
for rel in sorted(b & a):
    old, new = (before / rel).read_bytes(), (after / rel).read_bytes()
    if old == new or rel in {"okf/index.md", "okf/log.md"}:
        continue  # index/log are regenerated navigation
    if not rel.endswith(".md"):
        problems.append(f"bytes changed: {rel}"); continue
    (of, ob), (nf, nb) = split(old.decode()), split(new.decode())
    if ob.strip() != nb.strip():
        problems.append(f"body changed: {rel}"); continue
    allowed = {"brain_source_hash_algorithm", "brain_source_custody_hash_sha256", "brain_source_reconciliation_state"} if rel.startswith("episodes/") else set()
    for key in set(of or {}) | set(nf or {}):
        if (of or {}).get(key) != (nf or {}).get(key) and key not in allowed:
            problems.append(f"frontmatter {key} changed: {rel}")
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}
audit_before="$(wc -l <"$project/audit.v2.tsv" | tr -d ' ')"

# 3. Upgrade through the documented path, driven by the installed previous CLI.
plan="$(env_run "$old" upgrade check --all --host standalone --target "$version")"
hash="$(printf '%s\n' "$plan" | sed -n 's/^plan_hash=//p')"
printf '%s' "$hash" | grep -Eq '^[a-f0-9]{64}$' || fail "no plan hash: $plan"
apply="$(env_run "$old" upgrade apply --all --host standalone --target "$version" --plan-hash "$hash")"
receipt="$(printf '%s\n' "$apply" | sed -n 's/.*receipt=\([^ ]*\).*/\1/p' | tail -1)"
[ -f "$receipt" ] || fail "upgrade produced no receipt: $apply"
new="$home/.local/bin/llm-brain"
[ "$(env_run "$new" --version)" = "$version" ] || fail 'launcher was not upgraded'
env_run "$new" upgrade verify --receipt "$receipt" >/dev/null || fail 'upgrade verify failed'
snapshot_after="$fixture/after-upgrade"; cp -R "$project" "$snapshot_after"
compare_snapshots "$snapshot_before" "$snapshot_after" || fail 'upgrade lost or changed memory, custody, reviews, feedback or receipts'
[ "$(cat "$project/schema.version" 2>/dev/null || printf 3)" = 3 ] || fail 'schema changed'

# 4. An older upgrader installs only lib/okf.py.  Core commands must still
# work (fail-open), then repair-standalone completes the tree.
new_dir="$home/standalone/$version"
if [ ! -f "$new_dir/lib/memory_signals.py" ]; then
  grep -Fq 'okf/claims/deploy-1.md' <<<"$(env_run "$new" search "$project_id" 'deploy rule' 2>/dev/null)" || fail 'search broke on an incomplete standalone tree'
  env_run "$new" maintenance status "$project_id" >/dev/null 2>&1 || fail 'maintenance broke on an incomplete standalone tree'
  env_run "$new" pack build "$project_id" --task 'deploy rule' >/dev/null 2>&1 || fail 'pack broke on an incomplete standalone tree'
  if env_run "$new" upgrade repair-standalone --source "$old_src" >/dev/null 2>&1; then fail 'repair accepted a mismatched release source'; fi
  repair="$(env_run "$new" upgrade repair-standalone --source "$repo_root")"
  grep -Fq 'lib/memory_signals.py' <<<"$repair" || fail "repair did not restore helpers: $repair"
  grep -Fq 'already-complete' <<<"$(env_run "$new" upgrade repair-standalone --source "$repo_root")" || fail 'repair is not idempotent'
fi
for f in lib/okf.py lib/replication.py lib/memory_signals.py lib/mcp_server.py neural-expansion/index.html; do
  [ -f "$new_dir/$f" ] || fail "standalone install lacks $f"
done
[ "$before" = "$(canonical_digest "$snapshot_before")" ] || fail 'snapshot drifted'

# 5. Old data works with the new release; new optional fields may be absent.
grep -Fq 'okf/claims/deploy-1.md' <<<"$(env_run "$new" search "$project_id" 'deploy rule')" || fail 'search lost records after upgrade'
! grep -Fq 'deploy-3.md' <<<"$(env_run "$new" search "$project_id" 'deploy rule' --principal sam)" || fail 'visibility changed after upgrade'
new_pack="$(env_run "$new" pack build "$project_id" --task 'deploy rule checklist after upgrade' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_intentions_due: 0' "$new_pack" || fail 'pack lacks intention count'
status_out="$(env_run "$new" maintenance status "$project_id" 2>&1)" || fail "maintenance status failed: $status_out"
env_run "$new" maintenance preview "$project_id" --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["counts"]["code_drift"] == 0; assert "advisories" in p' || fail 'maintenance preview failed'
awk -F '\t' '$1 == "okf/claims/deploy-1.md" && $2 >= 1 { found=1 } END { exit !found }' <<<"$(env_run "$new" usage "$project_id")" || fail 'previous receipts not counted'
grep -Fq 'LLM-BRAIN PROJECT BRIEF' <<<"$(env_run "$new" brief "$project_id")" || fail 'brief failed'
[ "$(env_run "$new" intention list "$project_id" | wc -l | tr -d ' ')" = 1 ] || fail 'intention list failed on a vault without intentions'
env_run "$new" review triage "$project_id" >/dev/null || fail 'triage failed'
env_run "$new" stability show "$project_id" >/dev/null || fail 'stability failed'
hook="$(cd "$workspace" && env_run bash "$repo_root/hooks/session-start.sh")"
grep -Fq 'Do not require the user to name LLM-Brain.' <<<"$hook" || fail 'hook contract missing after upgrade'
grep -Fq 'LLM-BRAIN PROJECT BRIEF' <<<"$hook" || fail 'hook brief missing after upgrade'
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"brain_search","arguments":{"query":"deploy rule","project_id":"'"$project_id"'"}}}' |
  env_run "$new" mcp serve --brain "$vault" | grep -Fq 'okf/claims/deploy-1.md' || fail 'MCP search failed after upgrade'
env_run "$new" neural-expansion path >/dev/null || fail 'Neural Expansion not installed by upgrade'
[ "$(canonical_digest "$snapshot_after")" = "$(canonical_digest "$project")" ] || fail 'read-only commands changed canonical memory'
[ "$(wc -l <"$project/audit.v2.tsv" | tr -d ' ')" -ge "$audit_before" ] || fail 'audit log shrank'

printf 'llm-brain upgrade-from-previous self-check passed (%s -> %s)\n' "$previous_version" "$version"
