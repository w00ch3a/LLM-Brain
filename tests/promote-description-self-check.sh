#!/usr/bin/env bash
# Memthena: promotion writes an OKF `description:` (same rules as
# migrate okf-backfill) only when enabled (backfill active or
# LLM_BRAIN_PROMOTE_DESCRIPTION=1); restricted and secret-bearing records
# get none; search ranking ignores description.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-promote-desc.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PROMOTE_DESCRIPTION MEMTHENA_PROMOTE_DESCRIPTION
fail() { printf 'promote-description-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_pdesc"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mk() { # id title sensitivity body [extra]
  printf -- '---\ntype: ReviewItem\ntitle: "%s"\nbrain_project_id: %s\nbrain_candidate_id: %s\nbrain_review_kind: claim\nbrain_review_state: proposed\nbrain_confidence: 0.9\nbrain_risk: low\nbrain_sensitivity: %s\nbrain_loading_temperature: warm\nbrain_source_authority: user\nbrain_provider_id: fixture\nbrain_provider_version: "1"\nbrain_provenance: "episode://fixture"\n%sbrain_schema_version: 3\n---\n# %s\n\n%s\n' \
    "$2" "$project_id" "$1" "$3" "${5:-}" "$2" "$4" >"$project/review/$1.md"
}
promote() { "$cli" --root "$vault" review decide "$project_id" "$1" approved --actor human:test --reason fixture >/dev/null; }
lead="The harbour ferry leaves every twenty minutes on weekdays."
mk claim_off001 "Ferry off" internal "$lead More text."
mk claim_on0001 "Ferry on" internal "$lead More text."
mk claim_rst001 "Ferry restricted" restricted "$lead Restricted text."
mk claim_scp001 "Ferry scoped" internal "$lead Scoped text." 'brain_principal: "alice"\n'
# Default (no backfill active): bytes as before, no description.
promote claim_off001
! grep -q '^description:' "$project/okf/claims/claim_off001.md" || fail 'description written while off'
export LLM_BRAIN_PROMOTE_DESCRIPTION=1
promote claim_on0001
grep -Fxq "description: \"$lead\"" "$project/okf/claims/claim_on0001.md" || fail 'description missing when on'
python3 "$repo_root/lib/okf.py" validate "$project/okf/claims/claim_on0001.md" >/dev/null 2>&1 || "$cli" --root "$vault" lint >/dev/null || fail 'described record invalid'
promote claim_rst001; promote claim_scp001
for id in claim_rst001 claim_scp001; do
  ! grep -q '^description:' "$project/okf/claims/$id.md" || fail "restricted/owner-only record $id described"
done
# The audit hash is of the final bytes (description included).
hash="$(sha256sum "$project/okf/claims/claim_on0001.md" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$project/okf/claims/claim_on0001.md" | awk '{print $1}')"
grep -F 'review-promote' "$project/audit.v2.tsv" 2>/dev/null | grep -Fq "$hash" || grep -rFq "$hash" "$project"/audit* || fail 'audit hash does not match promoted bytes'
# Search ignores description: ranking with and without it is identical.
before="$("$cli" --root "$vault" search "$project_id" "harbour ferry" --limit 10 | cut -f1,2)"
python3 - "$project/okf/claims/claim_on0001.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write("".join(l for l in t.splitlines(True) if not l.startswith("description:")))
PY
after="$("$cli" --root "$vault" search "$project_id" "harbour ferry" --limit 10 | cut -f1,2)"
[ "$before" = "$after" ] || fail 'search ranking changed with description'
# =0 wins over an active backfill.
mkdir -p "$project/migrations/okf-backfill"; : >"$project/migrations/okf-backfill/active"
mk claim_zero01 "Ferry zero" internal "$lead More."
LLM_BRAIN_PROMOTE_DESCRIPTION=0 promote claim_zero01
! grep -q '^description:' "$project/okf/claims/claim_zero01.md" || fail '=0 did not turn it off'
unset LLM_BRAIN_PROMOTE_DESCRIPTION
mk claim_auto01 "Ferry auto" internal "$lead More."
promote claim_auto01
grep -q '^description:' "$project/okf/claims/claim_auto01.md" || fail 'auto with active backfill did not describe'
printf 'promote-description-self-check: ok\n'
