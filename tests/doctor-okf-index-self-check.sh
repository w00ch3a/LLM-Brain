#!/usr/bin/env bash
# 0.12.1: after `migrate okf-backfill --apply`, doctor must not treat the
# generated per-folder OKF index.md pages (or frontmatter-less log.md) as
# records.  A real record missing its validation timestamp, including one
# misnamed index.md that carries record frontmatter, is still flagged.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-doctor-okf-index.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'doctor-okf-index-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

record() { # path title [validated]
  local file="$1" title="$2" validated="${3:-}"
  mkdir -p "$(dirname "$file")"
  {
    printf -- '---\ntype: Claim\ntitle: %s\n' "$title"
    [ -z "$validated" ] || printf 'last_validated_at: %s\n' "$validated"
    printf -- '---\n# %s\n\nA lead sentence about %s. More detail here.\n' "$title" "$title"
  } >"$file"
}

for id in proj_legacy proj_current; do
  mkdir -p "$fixture/ws-$id"
  "$cli" --root "$vault" project ensure "$fixture/ws-$id" --id "$id" >/dev/null
  for folder in claims procedures references; do
    for i in 1 2; do record "$vault/projects/$id/okf/$folder/r$i.md" "$folder record $i" "$now"; done
  done
done
legacy="$vault/projects/proj_legacy"
printf '2\n' >"$legacy/schema.version"   # record-by-record doctor path

"$cli" --root "$vault" doctor --no-audit-replay >"$fixture/before.out" 2>&1 || fail "fixture doctor not clean before backfill: $(cat "$fixture/before.out")"

for id in proj_legacy proj_current; do
  "$cli" --root "$vault" migrate okf-backfill --apply --project "$id" >/dev/null || fail "backfill apply failed for $id"
done
for folder in claims procedures references; do
  generated="$legacy/okf/$folder/index.md"
  [ -f "$generated" ] || fail "backfill did not create $folder/index.md"
  head -n 1 "$generated" | grep -q '^<!-- memthena:okf-index v1' || fail "generated $folder/index.md lacks the backfill marker"
done

printf '# Log\n\n## 2026-10-26\n\n- note\n' >"$legacy/okf/claims/log.md"
# 1. Generated indexes and a plain log.md are navigation, not records.
if ! "$cli" --root "$vault" doctor --no-audit-replay >"$fixture/after.out" 2>&1; then
  fail "doctor reported findings after backfill: $(cat "$fixture/after.out")"
fi
grep -Eq 'validation timestamp: .*/(index|log)\.md' "$fixture/after.out" && fail "doctor flagged an OKF navigation file: $(cat "$fixture/after.out")"
grep -q 'doctor=ok' "$fixture/after.out" || fail "doctor not ok after backfill: $(cat "$fixture/after.out")"

# 2. A real record missing its timestamp is still flagged.
record "$legacy/okf/claims/no-stamp.md" "No stamp"
if "$cli" --root "$vault" doctor --no-audit-replay >"$fixture/missing.out" 2>&1; then fail "doctor passed a record without a validation timestamp"; fi
grep -q 'missing validation timestamp: projects/proj_legacy/okf/claims/no-stamp.md' "$fixture/missing.out" || fail "missing-timestamp record not flagged: $(cat "$fixture/missing.out")"
grep -Eq 'validation timestamp: .*/(index|log)\.md' "$fixture/missing.out" && fail "navigation file flagged alongside the real finding"
rm -f "$legacy/okf/claims/no-stamp.md"

# 3. A file named index.md that carries record frontmatter is not skipped.
mv "$legacy/okf/references/index.md" "$fixture/generated-index.md"
record "$legacy/okf/references/index.md" "Misnamed record"
if "$cli" --root "$vault" doctor --no-audit-replay >"$fixture/misnamed.out" 2>&1; then fail "doctor skipped a record named index.md"; fi
grep -q 'missing validation timestamp: projects/proj_legacy/okf/references/index.md' "$fixture/misnamed.out" || fail "record named index.md not checked: $(cat "$fixture/misnamed.out")"
mv "$fixture/generated-index.md" "$legacy/okf/references/index.md"
"$cli" --root "$vault" doctor --no-audit-replay >/dev/null 2>&1 || fail "doctor not clean after restoring the generated index"

printf 'doctor-okf-index-self-check=passed\n'
