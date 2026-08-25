#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-state.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
workspace="$fixture/workspace"
project_id="proj_state_commitment_capsule"
mkdir -p "$workspace"
git -C "$workspace" init -q
git -C "$workspace" remote add origin https://example.invalid/state.git
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims" "$project/okf/procedures" "$project/sources"

fail() { printf 'state/commitment/capsule self-check: %s\n' "$*" >&2; exit 1; }
assert_contains() { printf '%s' "$1" | grep -Fq -- "$2" || fail "expected output to contain: $2"; }
write_claim() {
  local file="$1" id="$2" title="$3" body="$4" extra="${5:-}"
  {
    printf '%s\n' '---' 'type: Claim' "title: $title" "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' "$body"
  } >"$file"
}

printf '%s\n' 'one root source' >"$project/sources/one.md"
printf '%s\n' 'two root source' >"$project/sources/two.md"
write_claim "$project/okf/claims/state-a.md" state-a 'Release state A' 'release state conflict marker' $'brain_state_key: release.current\nbrain_source_ref: sources/one.md'
write_claim "$project/okf/claims/state-b.md" state-b 'Release state B' 'release state conflict marker' $'brain_state_key: release.current\nbrain_source_ref: sources/one.md'
write_claim "$project/okf/claims/missing-dependency.md" missing-dependency 'Missing dependency state' 'missing dependency marker' 'brain_depends_on: does-not-exist'
write_claim "$project/okf/claims/cycle-a.md" cycle-a 'Cycle state A' 'cycle marker A' 'brain_depends_on: cycle-b'
write_claim "$project/okf/claims/cycle-b.md" cycle-b 'Cycle state B' 'cycle marker B' 'brain_depends_on: cycle-a'
write_claim "$project/okf/claims/evidence-a.md" evidence-a 'Evidence independence A' 'evidence independence marker' 'brain_source_ref: sources/one.md'
write_claim "$project/okf/claims/evidence-b.md" evidence-b 'Evidence independence B' 'evidence independence marker' 'brain_source_ref: sources/one.md'
write_claim "$project/okf/claims/evidence-c.md" evidence-c 'Evidence independence C' 'evidence independence marker' 'brain_source_ref: sources/two.md'
write_claim "$project/okf/claims/hidden-dependency.md" hidden-dependency 'Hidden dependency' 'hidden dependency marker'
sed 's/brain_sensitivity: internal/brain_sensitivity: restricted/' "$project/okf/claims/hidden-dependency.md" >"$fixture/hidden.md"
mv "$fixture/hidden.md" "$project/okf/claims/hidden-dependency.md"
write_claim "$project/okf/claims/inaccessible-parent.md" inaccessible-parent 'Inaccessible dependency state' 'inaccessible dependency marker' 'brain_depends_on: hidden-dependency'

state_output="$($cli --root "$vault" search "$project_id" 'release state conflict marker' --intent current_state --explain --limit 10)"
assert_contains "$state_output" $'state_reason\teffective_ref\tevidence_group'
assert_contains "$state_output" $'unresolved-conflict\tstable'
state_meta="$fixture/state.meta"
"$cli" --root "$vault" search "$project_id" 'release state conflict marker' --intent current_state --metadata-file "$state_meta" >/dev/null
assert_contains "$(cat "$state_meta")" 'state_resolution=enabled'
grep -Eq 'state_unresolved_count=[2-9][0-9]*' "$state_meta" || fail 'state unresolved count was not recorded'
printf '%s\n' 'release state conflict marker' >"$fixture/query.txt"
bridge_state="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --intent current_state --strategy lexical --budget-tokens 200)"
printf '%s\n' "$bridge_state" | python3 -c 'import json,sys; p=json.load(sys.stdin); c=p["context_markdown"]; marker="## State Warnings"; assert p["state_resolution"] == "enabled"; assert p["state_unresolved_count"] >= 2; assert marker in c; assert "unresolved-" not in c.split(marker,1)[0]; assert all("state_reason" in row for row in p["results"] if row["type"] != "HermesTurn" and len(row) > 0)'

missing_output="$($cli --root "$vault" search "$project_id" 'missing dependency marker' --intent current_state --explain --limit 5)"
assert_contains "$missing_output" 'unresolved-dependency'
cycle_output="$($cli --root "$vault" search "$project_id" 'cycle marker' --intent current_state --explain --limit 5)"
assert_contains "$cycle_output" 'invalid-cycle'
hidden_output="$($cli --root "$vault" search "$project_id" 'inaccessible dependency marker' --intent current_state --explain --limit 5)"
assert_contains "$hidden_output" 'unresolved-inaccessible'

evidence_output="$($cli --root "$vault" search "$project_id" 'evidence independence marker' --explain --limit 20)"
assert_contains "$evidence_output" 'custodied'
evidence_meta="$fixture/evidence.meta"
"$cli" --root "$vault" search "$project_id" 'evidence independence marker' --limit 3 --metadata-file "$evidence_meta" >/dev/null
assert_contains "$(cat "$evidence_meta")" 'independent_source_count=2'
assert_contains "$(cat "$evidence_meta")" 'correlated_record_count=2'
pack_output="$($cli --root "$vault" pack build "$project_id" --agent test --task 'release state conflict marker' --intent current_state --budget-tokens 200)"
pack_file="$(printf '%s\n' "$pack_output" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$pack_file" ] || fail 'current-state pack missing'
grep -Fq '## State Warnings' "$pack_file" || fail 'current-state pack omitted warnings'
grep -Fq 'brain_independent_source_count:' "$pack_file" || fail 'pack omitted independence metadata'
grep -Fq 'Evidence group:' "$pack_file" || fail 'pack omitted evidence-group metadata'

candidate="$fixture/ask.md"
{
  printf '%s\n' '---' 'type: ReviewItem' 'title: Ask before persisting' 'brain_review_kind: claim' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_source_authority: human-directive' 'brain_authority_origin: human-directive' 'brain_provider_id: fixture' 'brain_provider_version: 1' 'brain_provenance: "human://directive"' 'brain_commitment_action: ask' 'brain_commitment_reason: "The target is ambiguous."' 'brain_clarification_question: "Which target should this apply to?"' '---' '# Candidate' '' 'Ask before persisting.'
} >"$candidate"
ask_output="$(LLM_BRAIN_COMMITMENT_POLICY=enforce "$cli" --root "$vault" reflect submit "$project_id" "$candidate")"
assert_contains "$ask_output" 'commitment_action=ask'
ask_id="$(printf '%s\n' "$ask_output" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_review_state: needs-validation' "$project/review/$ask_id.md" || fail 'ask action was not held for validation'
commitment_file="$(find "$project/reflection/commitments" -type f -name '*.md' -print -quit)"
[ -n "$commitment_file" ] || fail 'commitment decision missing'
grep -Fq 'type: CommitmentDecision' "$commitment_file"

quarantine="$fixture/quarantine.md"
sed 's/title: Ask before persisting/title: Quarantine candidate/; s/brain_commitment_action: ask/brain_commitment_action: quarantine/' "$candidate" >"$quarantine"
quarantine_output="$(LLM_BRAIN_COMMITMENT_POLICY=enforce "$cli" --root "$vault" reflect submit "$project_id" "$quarantine")"
assert_contains "$quarantine_output" 'commitment_action=quarantine'
find "$project/quarantine" -type f -name '*.txt' -print -quit | grep -q . || fail 'quarantine artefact missing'

secret_candidate="$fixture/secret.md"
printf '%s\n' 'api_key=abcdefghijklmnop' >>"$secret_candidate"
if LLM_BRAIN_COMMITMENT_POLICY=enforce "$cli" --root "$vault" reflect submit "$project_id" "$secret_candidate" >/dev/null 2>&1; then
  fail 'secret candidate was accepted'
fi
grep -R -Fq 'secret-match' "$project/reflection/commitments" || fail 'secret commitment decision missing'

procedure="$project/okf/procedures/release.md"
{
  printf '%s\n' '---' 'type: Procedure' 'title: Capsule release' 'status: stable' "brain_project_id: $project_id" 'brain_procedure_id: capsule-release' 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_required_bindings: environment,branch' 'brain_applicability: release target' 'brain_prerequisites: clean tree' 'brain_verification: record the report' 'brain_schema_version: 3' '---' '# Capsule release' '' 'Run the release checks.'
} >"$procedure"
prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/release.md --task 'release checks' --principal hermes:test --binding environment=staging --binding branch=main --verification 'record report')"
prepared_again="$($cli --root "$vault" run prepare "$project_id" okf/procedures/release.md --task 'release checks' --principal hermes:test --binding environment=staging --binding branch=main --verification 'record report')"
capsule_id="$(printf '%s\n' "$prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
assert_contains "$prepared_again" "capsule_id=$capsule_id"
[ "$(find "$project/runs/prepared" -type f -name '*.md' | wc -l | tr -d ' ')" = 1 ] || fail 'prepare was not idempotent'
started="$($cli --root "$vault" run start "$project_id" okf/procedures/release.md --capsule "runs/prepared/$capsule_id.md" --request-id capsule-run-1)"
run_id="$(printf '%s\n' "$started" | sed -n 's/.*run_id=\([^ ]*\).*/\1/p')"
grep -Fq 'brain_task: "release checks"' "$project/runs/$run_id.md"
if "$cli" --root "$vault" run start "$project_id" okf/procedures/release.md --capsule "runs/prepared/$capsule_id.md" --task 'different task' --request-id capsule-run-2 >/dev/null 2>&1; then
  fail 'conflicting capsule task was accepted'
fi
printf '%s\n' 'changed procedure body' >>"$procedure"
if "$cli" --root "$vault" run start "$project_id" okf/procedures/release.md --capsule "runs/prepared/$capsule_id.md" --request-id capsule-run-3 >/dev/null 2>&1; then
  fail 'stale capsule was accepted'
fi

printf '%s\n' 'llm-brain state/commitment/capsule self-check passed'
