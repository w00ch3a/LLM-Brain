#!/usr/bin/env bash
# Index publication must complete on filesystems that cannot hold symlinks
# (CIFS/SMB without mfsymlinks) and on legacy projects without audit.v2.tsv:
# a failure after the generation is published used to leave rebuild-state
# stuck at "building".
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-index-portability.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'index-portability: %s\n' "$*" >&2; exit 1; }

# Shim ln so symbolic links fail the way a no-symlink CIFS mount does.
mkdir -p "$fixture/nosymlink"
cat >"$fixture/nosymlink/ln" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in -s|-sf|-sfn|-fs|-ns) printf "ln: failed to create symbolic link '%s': Operation not supported\n" "${!#}" >&2; exit 1 ;; esac
done
exec /bin/ln "$@"
EOF
chmod +x "$fixture/nosymlink/ln"

state_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$1/indexes/rebuild-state.json"; }

vault="$fixture/vault"; workspace="$fixture/workspace"; mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id proj_cifs >/dev/null
"$cli" --root "$vault" topic add proj_cifs "Symlink free storage" --id symlink-free >/dev/null
dir="$vault/projects/proj_cifs"
PATH="$fixture/nosymlink:$PATH" "$cli" --root "$vault" index build proj_cifs >/dev/null || fail "index build failed without symlink support"
[ "$(state_of "$dir")" = idle ] || fail "rebuild state not idle after no-symlink build"
generation="$(cat "$dir/indexes/current")"
for name in documents.tsv terms.tsv graph.tsv manifest.tsv; do
  [ -f "$dir/indexes/$name" ] && [ ! -L "$dir/indexes/$name" ] || fail "compat alias $name is not a regular file"
  cmp -s "$dir/indexes/$name" "$dir/indexes/generations/$generation/$name" || fail "compat alias $name differs from generation"
done
"$cli" --root "$vault" maintenance status proj_cifs | grep -q '^finding=index:primary' && fail "primary index still flagged after build"
"$cli" --root "$vault" search proj_cifs "symlink free" | grep -q 'symlink-free' || fail "search did not use the published index"
# A normal build afterwards still publishes symlink aliases.
"$cli" --root "$vault" index build proj_cifs >/dev/null
[ -L "$dir/indexes/documents.tsv" ] || fail "symlink alias not restored on a capable filesystem"

# Legacy project with no hash-chained audit yet.
"$cli" --root "$vault" project ensure "$fixture/legacy-ws" --id proj_legacy >/dev/null 2>&1 || { mkdir -p "$fixture/legacy-ws"; "$cli" --root "$vault" project ensure "$fixture/legacy-ws" --id proj_legacy >/dev/null; }
legacy="$vault/projects/proj_legacy"
rm -f "$legacy/audit.v2.tsv"
"$cli" --root "$vault" index build proj_legacy >/dev/null || fail "index build failed on a project without audit.v2.tsv"
[ "$(state_of "$legacy")" = idle ] || fail "legacy rebuild state not idle"
[ "$(wc -l <"$legacy/audit.v2.tsv" | tr -d ' ')" -ge 1 ] || fail "audit chain not started"
printf 'index-portability-self-check=ok\n'
