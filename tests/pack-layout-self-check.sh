#!/usr/bin/env bash
# #6 (16 Nov ideas): the same records laid out to suit the question --
# timeline for "when / what changed", current value first with replaced
# versions footnoted, conflicts side by side, steps first for "how do I".
# Default stays the 0.13 ranked layout; --layout auto opts in.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-pack-layout.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_PACK_LAYOUT
fail() { printf 'pack layout self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_layout"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$fixture/ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"; procs="$pdir/okf/procedures"; mkdir -p "$procs"
rec() { # dir type id title at body extra...
  local d="$1" t="$2" id="$3" title="$4" at="$5" body="$6"; shift 6
  { printf '%s\n' '---' "type: $t" "title: \"$title\"" 'status: stable' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"; } >"$d/$id.md"
}
# Timeline: three dated changes to the cache backend, written out of order.
rec "$claims" Claim cache-2025 'Cache backend moved to Valkey' 2025-03-01T00:00:00Z 'The cache backend changed from Redis to Valkey in March 2025; we decided this for licensing.' 'brain_claim_id: cache-2025'
rec "$claims" Claim cache-2023 'Cache backend first set up on Memcached' 2023-05-01T00:00:00Z 'The cache backend was first set up on Memcached in May 2023.' 'brain_claim_id: cache-2023'
rec "$claims" Claim cache-2024 'Cache backend moved to Redis' 2024-02-01T00:00:00Z 'The cache backend changed from Memcached to Redis in February 2024.' 'brain_claim_id: cache-2024'
# Current value: a state key with an older replaced value.
rec "$claims" Claim port-old 'Ingest port' 2026-01-01T00:00:00Z 'The ingest service listens on port 7000.' 'brain_claim_id: port-old' 'brain_state_key: ingest-port'
rec "$claims" Claim port-new 'Ingest port changed' 2026-06-01T00:00:00Z 'The ingest service listens on port 7443.' 'brain_claim_id: port-new' 'brain_state_key: ingest-port' 'brain_supersedes: ["okf/claims/port-old.md"]'
rec "$claims" Claim ingest-note 'Ingest service notes' 2026-07-01T00:00:00Z 'The ingest service port is documented in the ops sheet; ingest service port checks run each evening. The ingest service port matters for the firewall.' 'brain_claim_id: ingest-note'
# Steps: a long note that out-ranks the procedure on words.
rec "$claims" Claim rotate-note 'Rotate signing key background' 2026-02-01T00:00:00Z "$(for i in 1 2 3; do printf 'Rotate the signing key rotation background %s: signing key rotation is quarterly; rotate signing key on schedule. ' "$i"; done)" 'brain_claim_id: rotate-note'
rec "$procs" Procedure rotate-key 'Rotate the signing key' 2026-02-02T00:00:00Z "$(printf '%s\n' 'Use this when the signing key is due; we decided on quarterly rotation.' '' '1. Generate the new signing key with keytool.' '2. Upload the public half to the verifier.' '3. Switch signers and retire the old key after 24 hours.')"
# Conflict: two sides on the backup window.
rec "$claims" Claim backup-a 'Backup window (desk)' 2026-03-01T00:00:00Z 'Nightly backups run at 01:00 UTC.' 'brain_claim_id: backup-a' 'brain_conflicts: [okf/claims/backup-b.md]'
rec "$claims" Claim backup-b 'Backup window (ops)' 2026-04-01T00:00:00Z 'Nightly backups run at 03:00 UTC.' 'brain_claim_id: backup-b' 'brain_conflicts: [okf/claims/backup-a.md]' 'brain_source_authority: imported-doc'
sed -i '0,/brain_source_authority: human-directive/{/brain_source_authority: human-directive/d}' "$claims/backup-b.md"
pack() { b pack build "$project_id" --agent "a$RANDOM" --budget-tokens 1200 --task "$@" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
heads() { grep '^### ' "$1" | sed 's/^### //'; }
checks=()

# 0. Default is the 0.13 ranked layout: no layout line, same hash as --layout ranked.
p1="$(b pack build "$project_id" --task 'when did the cache backend change' --agent same)"
p2="$(b pack build "$project_id" --task 'when did the cache backend change' --agent same --layout ranked)"
grep -q '^pack=idempotent' <<<"$p2" || fail "explicit ranked differs from default: $p1 / $p2"
f="$(sed -n 's/.*file=\([^ ]*\).*/\1/p' <<<"$p1")"
! grep -q '^Layout:\|^brain_layout:' "$f" || fail 'default pack carries a layout'
checks+=(default_ranked_unchanged=ok)

# 1. Timeline for "when ... change".
p="$(pack 'when did the cache backend change' --layout auto)"
grep -q '^brain_layout: timeline$' "$p" || fail "timeline not chosen: $(grep '^Layout' "$p" || true)"
grep -q '^## Timeline — oldest first' "$p" || fail 'timeline section missing'
order="$(heads "$p" | grep -n 'Cache backend' | cut -d: -f2 | tr '\n' '|')"
[ "$order" = 'Cache backend first set up on Memcached|Cache backend moved to Redis|Cache backend moved to Valkey|' ] || fail "timeline order wrong: $order"
grep -A4 '^## Timeline' "$p" | grep -q '^- 2023-05-01 — Cache backend first set up' || fail 'timeline entry missing its date'
checks+=(timeline=ok)

# 2. Current value first, replaced version footnoted (and not as a record).
p="$(pack 'what is the ingest service port' --layout auto)"
grep -q '^brain_layout: current-first$' "$p" || fail "current-first not chosen: $(grep '^Layout' "$p" || true)"
[ "$(heads "$p" | head -n 1)" = 'Ingest port changed' ] || fail "current value not first: $(heads "$p" | head -n 1)"
grep -A2 '^## Current value' "$p" | grep -q 'port 7443' || fail 'current value lead missing'
grep -A3 '^## Earlier versions (footnote)' "$p" | grep -q 'port 7000.*okf/claims/port-old.md' || fail 'replaced version not footnoted'
! heads "$p" | grep -qx 'Ingest port' || fail 'replaced version shown as a record'
checks+=(current_first=ok)

# 3. Steps first for "how do I".
pr="$(pack 'how do I rotate the signing key' --layout ranked)"
[ "$(heads "$pr" | head -n 1)" = 'Rotate signing key background' ] || fail "fixture: procedure already first under ranked ($(heads "$pr" | head -n 1))"
p="$(pack 'how do I rotate the signing key' --layout auto)"
grep -q '^brain_layout: steps$' "$p" || fail "steps not chosen: $(grep '^Layout' "$p" || true)"
[ "$(heads "$p" | head -n 1)" = 'Rotate the signing key' ] || fail 'procedure not first'
grep -A5 '^## Steps first' "$p" | grep -q '^1\. Generate the new signing key' || fail 'steps not lifted to the top'
checks+=(steps_first=ok)

# 4. Open conflict side by side (beats the other cues).
p="$(pack 'when do nightly backups run' --layout auto)"
grep -q '^brain_layout: side-by-side$' "$p" || fail "side-by-side not chosen: $(grep '^Layout' "$p" || true)"
grep -q '^| Says | Nightly backups run at 01:00 UTC. | Nightly backups run at 03:00 UTC. |$' "$p" || fail 'conflict table missing'
grep -q '^| Authority | human-directive | imported-doc |$' "$p" || fail 'authorities not side by side'
grep -q "^| Source | fixture | fixture |$" "$p" || fail "sources not side by side"
checks+=(side_by_side=ok)

# 5. No cue: auto falls back to ranked order, records unchanged.
pr="$(pack 'signing key' --layout ranked)"; pa="$(pack 'signing key' --layout auto)"
[ "$(heads "$pr")" = "$(heads "$pa")" ] || fail 'auto reordered a task with no cue'
grep -q '^brain_layout: ranked$' "$pa" || fail 'auto fallback not recorded'
checks+=(no_cue_ranked=ok)

# 6. Env switch and bad value.
p="$(LLM_BRAIN_PACK_LAYOUT=timeline pack 'cache backend')"
grep -q '^brain_layout: timeline$' "$p" || fail 'LLM_BRAIN_PACK_LAYOUT ignored'
set +e; b pack build "$project_id" --task x --layout sideways >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 64 ] || fail "bad layout rc=$rc"
checks+=(env_and_validation=ok)
# 7. A/B in the personal eval (synthetic brain only): ranked vs auto.
hid() { printf '%s' "$project_id/$1" | sha256sum | cut -c1-16; }
printf '%s\t%s\n' "$(hid okf/claims/port-new.md)" 'what is the ingest service port now' \
  "$(hid okf/claims/cache-2025.md)" 'when did the cache backend change' \
  "$(hid okf/procedures/rotate-key.md)" 'how do I rotate the signing key' >"$fixture/queries.tsv"
ab="$(python3 "$repo_root/scripts/personal-eval.py" --brain "$vault" --project "$project_id" --output "$fixture/ab" --filler 6 --seed 5 --queries "$fixture/queries.tsv" --layout-ab)"
printf '%s\n' "$ab" | grep '^layout-ab'
python3 - "$fixture/ab/summary.json" <<'PYCHK' || fail 'layout A/B summary wrong'
import json, sys
s = json.load(open(sys.argv[1]))
ab = s["layout_ab"]
assert s["cases"] == 3 and s["query_overrides"] == 3 and s["source_unchanged"], s
assert ab["b"]["hits"] >= ab["a"]["hits"] and ab["lost_in_b"] == 0 and ab["pack_failures_b"] == 0, ab
assert set(ab["layouts_chosen"]) <= {"ranked", "timeline", "current-first", "side-by-side", "steps"}, ab
assert ab["b"]["first_mention_median"] <= ab["a"]["first_mention_median"], ab
PYCHK
checks+=(personal_eval_ab=ok)
printf 'pack layout self-check passed: %s\n' "${checks[*]}"
