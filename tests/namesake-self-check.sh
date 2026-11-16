#!/usr/bin/env bash
# #7a (16 Nov ideas): look-alike names never merge.  People, projects and
# hosts with near-identical (or identical) names but different ids are kept
# apart at promotion, in triage, doctor and health advice, and packs say what
# tells them apart.  Includes the lifecycle-eval namesake set.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-namesake.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
unset LLM_BRAIN_NAMESAKE_GUARD LLM_BRAIN_PACK_NAMESAKE_LABELS
fail() { printf 'namesake self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_names"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$fixture/ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
rec() { # id title at body extra...
  local id="$1" title="$2" at="$3" body="$4"; shift 4
  { printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "fixture"}]' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"; } >"$claims/$id.md"
}
candidate() { # id title body extra...
  local id="$1" title="$2" body="$3"; shift 3
  { printf '%s\n' '---' 'type: ReviewItem' "title: \"$title\"" "brain_project_id: $project_id" "brain_candidate_id: $id" 'brain_review_kind: claim' 'brain_review_state: proposed' 'brain_confidence: 0.9' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_provider_id: fixture' 'brain_provider_version: "1"' 'brain_provenance: human://fixture'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"; } >"$fixture/$id.md"
  b reflect submit "$project_id" "$fixture/$id.md" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p'
}
decide() { set +e; out="$(b review decide "$project_id" "$@" --actor human:test --reason fixture 2>&1)"; rc=$?; set -e; }
rec alex-chen 'Alex Chen' 2026-03-01T00:00:00Z 'Alex Chen (payroll, EMP-1042) uses laptop LT-4471.' 'brain_entity_id: "person:EMP-1042"'
rec nas-01 'Host nas-01' 2026-04-01T00:00:00Z 'Host nas-01 at 10.0.4.11 holds the design share backups.'
rec staging-port 'Staging port' 2026-01-01T00:00:00Z 'The staging deploy listens on port 8080.'
checks=()

# 1. A review that supersedes a different person with a look-alike name is held (exit 75).
r="$(candidate cheng 'Alex Cheng' 'Alex Cheng (support, EMP-2290) uses laptop LT-9902.' 'brain_entity_id: "person:EMP-2290"' 'brain_supersedes: ["okf/claims/alex-chen.md"]')"
decide "$r" approved
[ "$rc" = 75 ] || fail "namesake supersession not held (rc=$rc): $out"
grep -Fq 'different entity with a look-alike name' <<<"$out" || fail "hold message unclear: $out"
grep -q 'namesake-hold' "$pdir/audit.v2.tsv" || fail 'hold not audited'
[ ! -e "$claims/$r.md" ] && [ ! -e "$claims/cheng.md" ] || fail 'held review was promoted'
checks+=(namesake_supersession_held=ok)
# Text ids alone (no brain_entity_id) are enough: a different host IP.
r2="$(candidate nas02 'Host nas-02' 'Host nas-02 at 10.0.4.12 holds the media share.' 'brain_supersedes: ["okf/claims/nas-01.md"]')"
decide "$r2" approved; [ "$rc" = 75 ] || fail "host namesake not held (rc=$rc): $out"
checks+=(text_ids_held=ok)

# 2. --same-entity confirms on purpose (audited), and promotes.
decide "$r2" approved --same-entity; [ "$rc" = 0 ] || fail "--same-entity did not promote (rc=$rc): $out"
grep -q 'same-entity-confirmed' "$pdir/audit.v2.tsv" || fail '--same-entity not audited'
checks+=(same_entity_override=ok)

# 3. A second person with the very same name gets their own record (0.13 made a conflict review).
r3="$(candidate chen-sales 'Alex Chen' 'Alex Chen (sales, EMP-3310) covers the northern territory.' 'brain_entity_id: "person:EMP-3310"')"
decide "$r3" approved; [ "$rc" = 0 ] || fail "same-name different person not promoted (rc=$rc): $out"
f3="$(grep -l 'EMP-3310' "$claims"/*.md | head -n 1)"; [ -n "$f3" ] || fail 'second Alex Chen missing'
grep -q '^brain_entity_id: "person:EMP-3310"$' "$f3" || fail "entity id not carried to the record: $(grep entity "$f3" || true)"
grep -q '^brain_review_state: approved$' "$claims/alex-chen.md" || fail 'first Alex Chen changed'
checks+=(same_name_kept_apart=ok)

# 4. Ordinary supersession without ids is untouched.
r4="$(candidate port-new 'Staging port moved' 'The staging deploy listens on port 8443.' 'brain_supersedes: ["okf/claims/staging-port.md"]')"
decide "$r4" approved; [ "$rc" = 0 ] || fail "plain supersession held (rc=$rc): $out"
checks+=(plain_supersession_unchanged=ok)

# 5. Packs say what tells look-alikes apart.
b index build "$project_id" >/dev/null
p="$(b pack build "$project_id" --task 'Alex Chen laptop territory' --agent t1 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Look-alike name, different entity: this one is entity `person:emp-1042` · project `proj_names` · recorded 2026-03-01' "$p" || fail "pack lacks disambiguation: $(grep -F 'Look-alike' "$p" || echo none)"
grep -Fq 'entity `person:emp-3310`' "$p" || fail 'other side not named'
p0="$(LLM_BRAIN_PACK_NAMESAKE_LABELS=0 b pack build "$project_id" --task 'Alex Chen laptop territory' --agent t2 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Look-alike' "$p0" || fail 'labels not switched off'
pp="$(b pack build "$project_id" --task 'staging deploy port' --agent t3 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Look-alike' "$pp" || fail 'label on records without ids'
checks+=(pack_disambiguates=ok)

# 6. Triage, doctor and health never advise merging distinct namesakes.
r5="$(candidate chen-3 'Alex Chen' 'Alex Chen (legal, EMP-4410) signs contracts.' 'brain_entity_id: "person:EMP-4410"')"
t="$(b review triage "$project_id" | awk -F '\t' -v id="$r5" '$1 == id')"
grep -q 'namesake-of-existing-title' <<<"$t" || fail "triage calls it a fit: $t"
b review triage "$project_id" | awk -F "\t" -v id="$r" '$1 == id' | grep -q "conflict.*namesake-distinct-entity" || fail "held namesake not triaged as a conflict"
d="$(python3 "$repo_root/lib/memory_signals.py" doctor --project-dir "$pdir")"
grep -q 'namesake-distinct.*keep-apart' <<<"$d" || fail "doctor lacks namesake row: $d"
! grep 'likely-duplicate' <<<"$d" | grep -q 'alex-chen' || fail "doctor offers to merge namesakes: $d"
cp "$claims/alex-chen.md" "$claims/alex-chen-copy.md"
sed -i 's/EMP-1042/EMP-5550/g; s/LT-4471/LT-5551/; s/brain_claim_id: alex-chen/brain_claim_id: alex-chen-copy/' "$claims/alex-chen-copy.md"
h="$(b health "$project_id" 2>&1 || true)"
grep -q 'namesake' <<<"$h" || fail "health lacks namesake finding: $h"
! grep 'near-duplicate-name' <<<"$h" | grep -q 'alex-chen' || fail "health advises merging namesakes: $h"
checks+=(no_merge_advice=ok)

# 7. Off switch.
r6="$(candidate cheng-off 'Alex Cheng' 'Alex Cheng (support, EMP-2290) uses laptop LT-9902.' 'brain_entity_id: "person:EMP-2290"' 'brain_supersedes: ["okf/claims/alex-chen.md"]')"
LLM_BRAIN_NAMESAKE_GUARD=0 decide "$r6" approved
[ "$rc" = 0 ] || fail "guard off still held (rc=$rc)"
checks+=(opt_out=ok)

# 8. Lifecycle-eval namesake set: every store step right, both namesakes current.
python3 "$repo_root/scripts/eval-lifecycle.py" --cases "$repo_root/tests/fixtures/lifecycle/namesakes.v1.json" --output "$fixture/lifecycle" --seed 0 --repeats 1 --step-checks >/dev/null
python3 - "$fixture/lifecycle/summary.json" <<'PYCHK' || fail 'lifecycle namesake set failed'
import json, sys
s = json.load(open(sys.argv[1]))
steps = s["step_checks"]
assert steps["checked"] == 4 and steps["correct"] == 4, steps
for mode in ("factual", "explicit", "evidence"):
    m = s["modes"][mode]
    assert m["gold_hit_rate"] == 1.0 and m["state_correct_rate"] == 1.0 and m["correctness_rate"] == 1.0, (mode, m)
print(f"lifecycle namesakes: steps {steps['correct']}/{steps['checked']}, factual correctness {s['modes']['factual']['correctness_rate']}")
PYCHK
checks+=(lifecycle_namesakes=ok)
printf 'namesake self-check passed: %s\n' "${checks[*]}"
