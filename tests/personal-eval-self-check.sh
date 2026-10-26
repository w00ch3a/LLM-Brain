#!/usr/bin/env bash
# Idea 9: scripts/personal-eval.py on a SYNTHETIC brain only.  It must leave
# the source untouched, mine corrections/decisions (records and sessions),
# score packs among filler, and write hashes and scores only.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
kit="$repo_root/scripts/personal-eval.py"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-personal-eval.XXXXXX")"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'personal-eval-self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_personal"
"$cli" --root "$vault" project ensure "$fixture/ws" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims" "$project/episodes/2026-10-01"
claim() { # id title sensitivity extra body
  {
    printf '%s\n' '---' 'type: Claim' "title: $2" 'status: stable'
    printf '%s\n' 'generated: {by: process:test, at: 2026-08-07T00:00:00Z}' 'sources: [{resource: source://fixture}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved'
    printf '%s\n' 'brain_confidence: 0.95' 'brain_risk: low' "brain_sensitivity: $3"
    printf '%s\n' 'brain_source_authority: repository' 'brain_provenance: human://fixture'
    [ -z "$4" ] || printf '%s\n' "$4"
    printf '%s\n' 'brain_schema_version: 3' '---' "# $2" '' "$5"
  } >"$project/okf/claims/$1.md"
}
claim claim_zephyrdecide 'Zephyrine queue choice' internal '' 'We decided the zephyrine queue uses the quillback broker for invoices.'
claim claim_marlowfix 'Marlowe port setting' internal 'brain_supersedes: claim_marlowold' 'The marlowe gateway listens on port 8443 behind the tessellate proxy.'
claim claim_sessionfix 'Brindle cache expiry' internal 'brain_provenance_episode: episode_20261001_aaaaaaaaaaaa' 'Brindle cache entries expire after ninety minutes on the obsidian cluster.'
claim claim_secretdec 'Canary vault decision' restricted '' 'We decided PERSONAL-EVAL-CANARY-7f3a lives in the restricted vault.'
claim claim_plain1 'Kettle descaling' internal '' 'The kettle on level two is descaled monthly.'
episode() { # id body
  printf '%s\n' '---' 'type: Episode' "title: \"Session $1\"" "brain_project_id: $project_id" "brain_episode_id: $1" \
    'brain_review_state: captured' 'brain_sensitivity: internal' 'brain_schema_version: 3' 'timestamp: "2026-10-01T00:00:00Z"' '---' "# Session" '' "$2" \
    >"$project/episodes/2026-10-01/$1.md"
}
episode episode_20261001_aaaaaaaaaaaa 'User corrected the agent: brindle cache expiry is ninety minutes, not thirty.'
episode episode_20261001_bbbbbbbbbbbb 'We decided to rename the gorsefield job; nothing promoted yet.'
"$cli" --root "$vault" index build "$project_id" >/dev/null

# Source fingerprint (content + mode) before.
fp() { (cd "$vault" && find . -path ./.locks -prune -o -type f -print | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$f" | cut -d' ' -f1)"; done; find . -path ./.locks -prune -o -print | LC_ALL=C sort | xargs stat -c '%n %a' 2>/dev/null || true); }
before="$(fp)"

# Refuses an output inside the brain.
if python3 "$kit" --brain "$vault" --project "$project_id" --output "$vault/report" >/dev/null 2>"$fixture/err"; then fail 'accepted output inside brain'; fi
grep -q '^memthena: personal-eval refused' "$fixture/err" || fail 'refusal lacks memthena: prefix'
[ ! -e "$vault/report" ] || fail 'wrote inside brain'

out="$fixture/report"
mkdir -p "$fixture/tmp"
stdout="$(env TMPDIR="$fixture/tmp" MEMTHENA_ROOT=/nonexistent/real-brain python3 "$kit" --brain "$vault" --project "$project_id" --output "$out" --filler 12 --seed 3)"
grep -Fq 'personal-eval=ok' <<<"$stdout" || fail 'kit did not report ok'
grep -Fq 'source_unchanged=true' <<<"$stdout" || fail 'source changed'
[ "$before" = "$(fp)" ] || fail 'source brain modified'
[ -f "$out/results.tsv" ] && [ -f "$out/summary.json" ] || fail 'missing outputs'
[ "$(find "$out" -type f | wc -l | tr -d ' ')" = 2 ] || fail 'unexpected output files'

python3 - "$out/summary.json" "$out/results.tsv" <<'PYCHK'
import json, sys
s = json.load(open(sys.argv[1]))
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2])][1:]
assert s["format"] == "memthena.personal-eval", s
# decision record, supersedes-correction, session-linked correction; restricted excluded.
assert s["cases"] == 3, s
assert s["by_kind"]["decision"]["cases"] == 1 and s["by_kind"]["correction"]["cases"] == 2, s
assert s["unpromoted_sessions"] == 1, s
assert s["filler_records"] == 12, s
assert s["hits"] >= 2, s
assert s["source_unchanged"] is True, s
assert s["pack_failures"] == 0, s
assert any(r[3] == "session" for r in rows), rows
for r in rows:
    assert len(r[0]) == 16 and len(r[1]) == 16 and all(c in "0123456789abcdef" for c in r[0] + r[1]), r
PYCHK

# Hashes and scores only: no record text, title, id, query or path leaks.
for needle in zephyrine quillback marlowe tessellate brindle obsidian gorsefield kettle PERSONAL-EVAL-CANARY claim_ episode_ okf/ "$project_id" 'follow up'; do
  ! grep -rqi -- "$needle" "$out" || fail "output leaks: $needle"
  ! grep -qi -- "$needle" <<<"$stdout" || fail "stdout leaks: $needle"
done
# Temporary copies are gone.
[ -z "$(find "$fixture/tmp" -mindepth 1 -maxdepth 1 2>/dev/null)" ] || fail 'scratch copy left behind'

# Deterministic for a seed.
python3 "$kit" --brain "$vault" --project "$project_id" --output "$fixture/report2" --filler 12 --seed 3 >/dev/null
cmp -s "$out/results.tsv" "$fixture/report2/results.tsv" || fail 'not deterministic'
printf 'personal-eval-self-check: ok\n'
