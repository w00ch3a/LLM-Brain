#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-research-upgrades.XXXXXX")"
cleanup_fixture() {
  if [ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ]; then
    printf 'research fixture retained: %s\n' "$fixture" >&2
    return 0
  fi
  rm -rf "$fixture"
}
trap cleanup_fixture EXIT

vault="$fixture/vault"
workspace="$fixture/workspace"
project_id="proj_research_upgrades"
mkdir -p "$workspace"
git -C "$workspace" init -q
git -C "$workspace" remote add origin https://example.invalid/research-upgrades.git
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
mkdir -p "$project/okf/claims" "$project/okf/procedures" "$project/sources"

fail() { printf 'research upgrades self-check: %s\n' "$*" >&2; exit 1; }
assert_contains() {
  local value="$1" needle="$2"
  case "$value" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}
assert_not_contains() {
  local value="$1" needle="$2"
  case "$value" in
    *"$needle"*) fail "output unexpectedly contained: $needle" ;;
    *) ;;
  esac
}
write_claim() {
  local file="$1" id="$2" title="$3" body="$4" extra="${5:-}"
  {
    printf '%s\n' '---' 'type: Claim' "title: $title" "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' "$body"
  } >"$file"
}
write_claim_window() {
  local file="$1" id="$2" title="$3" body="$4" valid_from="$5" valid_to="$6" extra="${7:-}"
  {
    printf '%s\n' '---' 'type: Claim' "title: $title" "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository' "brain_valid_from: \"$valid_from\"" "brain_valid_to: \"$valid_to\"" 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' "$body"
  } >"$file"
}
write_claim_sensitivity() {
  local file="$1" id="$2" title="$3" body="$4" sensitivity="$5" extra="${6:-}"
  {
    printf '%s\n' '---' 'type: Claim' "title: $title" "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' "brain_sensitivity: $sensitivity" 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_schema_version: 3'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '%s\n' '---' "# $title" '' "$body"
  } >"$file"
}
write_procedure() {
  local file="$1" id="$2" title="$3" dependency="$4"
  {
    printf '%s\n' '---' 'type: Procedure' "title: $title" 'status: stable' "brain_project_id: $project_id" "brain_procedure_id: $id" 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_required_bindings: environment' 'brain_applicability: release target' 'brain_prerequisites: clean tree' 'brain_verification: record the report' 'brain_schema_version: 3'
    [ -z "$dependency" ] || printf '%s\n' "brain_depends_on: $dependency"
    printf '%s\n' '---' "# $title" '' 'Run the release checks.'
  } >"$file"
}

write_claim "$project/okf/claims/release-region.md" release-region 'Release region' 'release region current'
write_claim "$project/okf/claims/release-target.md" release-target 'Release target' 'release target current' 'brain_state_key: release.target
brain_depends_on: okf/claims/release-region.md'
procedure="$project/okf/procedures/release.md"
write_procedure "$procedure" release 'Capsule release' okf/claims/release-target.md

prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/release.md --task 'release checks' --principal hermes:test --binding environment=staging)"
capsule_id="$(printf '%s\n' "$prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
[ -n "$capsule_id" ] || fail 'capsule was not prepared'
capsule="$project/runs/prepared/$capsule_id.md"
grep -Fq 'okf/claims/release-target.md' "$capsule" || fail 'capsule omitted direct dependency'
grep -Fq 'okf/claims/release-region.md' "$capsule" || fail 'capsule omitted transitive dependency'

valid_json="$($cli --root "$vault" run validate "$project_id" "runs/prepared/$capsule_id.md" --principal hermes:test --json)"
printf '%s\n' "$valid_json" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "valid"; assert value["dependency_state"] == "current"'

tampered="$fixture/tampered-capsule.md"
sed 's/^brain_task: .*/brain_task: tampered task/' "$capsule" >"$tampered"
tampered_json="$($cli --root "$vault" run validate "$project_id" "$tampered" --principal hermes:test --json 2>/dev/null || true)"
printf '%s\n' "$tampered_json" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] != "valid"'

printf '%s\n' 'transitive dependency changed' >>"$project/okf/claims/release-region.md"
stale_json="$($cli --root "$vault" run validate "$project_id" "runs/prepared/$capsule_id.md" --principal hermes:test --json 2>/dev/null || true)"
printf '%s\n' "$stale_json" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "stale"; assert value["reason"].startswith("dependency-")'
sed '$d' "$project/okf/claims/release-region.md" >"$fixture/release-region-restored.md"
mv "$fixture/release-region-restored.md" "$project/okf/claims/release-region.md"

hidden_claim="$project/okf/claims/hidden.md"
write_claim_sensitivity "$hidden_claim" hidden 'Hidden dependency' 'hidden dependency secret' restricted
hidden_hash="$(shasum -a 256 "$hidden_claim" | awk '{print $1}')"
hidden_procedure="$project/okf/procedures/hidden.md"
write_procedure "$hidden_procedure" hidden 'Hidden procedure' okf/claims/hidden.md
if hidden_output="$($cli --root "$vault" run prepare "$project_id" okf/procedures/hidden.md --task 'hidden' --principal hermes:test --binding environment=staging 2>&1)"; then
  fail 'restricted dependency was accepted'
fi
assert_not_contains "$hidden_output" 'hidden.md'
assert_not_contains "$hidden_output" 'Hidden dependency'
assert_not_contains "$hidden_output" 'hidden dependency secret'
assert_not_contains "$hidden_output" "$hidden_hash"

# Keep malformed duplicate-key rejection covered separately from the valid
# restricted-record policy above; a parser failure must not masquerade as a
# sensitivity enforcement test.
duplicate_hidden="$project/okf/claims/duplicate-hidden.md"
{
  printf '%s\n' '---' 'type: Claim' 'title: Duplicate restricted metadata' "brain_project_id: $project_id" 'brain_claim_id: duplicate-hidden' 'brain_review_state: approved' 'brain_sensitivity: internal' 'brain_sensitivity: restricted' 'brain_source_authority: repository' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' 'brain_schema_version: 3' '---' '# Duplicate restricted metadata'
} >"$duplicate_hidden"
duplicate_procedure="$project/okf/procedures/duplicate-hidden.md"
write_procedure "$duplicate_procedure" duplicate-hidden 'Duplicate hidden procedure' okf/claims/duplicate-hidden.md
if duplicate_output="$($cli --root "$vault" run prepare "$project_id" okf/procedures/duplicate-hidden.md --task 'duplicate hidden' --principal hermes:test --binding environment=staging 2>&1)"; then
  fail 'duplicate-key restricted dependency was accepted'
fi
assert_not_contains "$duplicate_output" 'restricted lifecycle secret'

alice_claim="$project/okf/claims/alice.md"
write_claim "$alice_claim" alice 'Alice dependency' 'alice-only dependency' 'brain_principal: alice'
alice_procedure="$project/okf/procedures/alice.md"
write_procedure "$alice_procedure" alice 'Alice procedure' okf/claims/alice.md
if "$cli" --root "$vault" run prepare "$project_id" okf/procedures/alice.md --task 'alice' --principal alice-bot --binding environment=staging >/dev/null 2>&1; then
  fail 'alice-bot matched alice dependency'
fi
alice_capsule="$($cli --root "$vault" run prepare "$project_id" okf/procedures/alice.md --task 'alice' --principal alice --binding environment=staging)"
assert_contains "$alice_capsule" 'capsule_id='
alice_capsule_id="$(printf '%s\n' "$alice_capsule" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"

copy_workspace="$fixture/copy-workspace"
mkdir -p "$copy_workspace"
git -C "$copy_workspace" init -q
git -C "$copy_workspace" remote add origin https://example.invalid/research-upgrades-copy.git
copy_id="proj_research_upgrades_copy"
"$cli" --root "$vault" project ensure "$copy_workspace" --id "$copy_id" >/dev/null
copy_project="$vault/projects/$copy_id"
mkdir -p "$copy_project/okf/claims" "$copy_project/okf/procedures" "$copy_project/runs/prepared"
cp "$project/okf/claims/release-region.md" "$copy_project/okf/claims/release-region.md"
cp "$project/okf/claims/release-target.md" "$copy_project/okf/claims/release-target.md"
cp "$procedure" "$copy_project/okf/procedures/release.md"
cp "$capsule" "$copy_project/runs/prepared/$capsule_id.md"
if "$cli" --root "$vault" run validate "$copy_id" "runs/prepared/$capsule_id.md" --principal hermes:test >/dev/null 2>&1; then
  fail 'capsule copied across projects was accepted'
fi

# References may use an approved record identifier, but the capsule must bind
# the resolved path and every transitive byte hash. A future-valid replacement
# must not supersede a record before its validity window begins.
alias_target="$project/okf/claims/alias-target.md"
write_claim "$alias_target" alias-target 'Alias target' 'alias target current marker'
alias_procedure="$project/okf/procedures/alias.md"
write_procedure "$alias_procedure" alias 'Alias procedure' alias-target
alias_prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/alias.md --task 'alias checks' --principal hermes:test --binding environment=staging)"
alias_capsule_id="$(printf '%s\n' "$alias_prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
alias_capsule="$project/runs/prepared/$alias_capsule_id.md"
alias_dependency_refs="$(python3 "$repo_root/lib/okf.py" field "$alias_capsule" brain_dependency_refs)"
printf '%s\n' "$alias_dependency_refs" | grep -Eq 'alias-target(\.md)?' || fail 'identifier alias was not canonicalised in capsule'
alias_valid="$($cli --root "$vault" run validate "$project_id" "runs/prepared/$alias_capsule_id.md" --principal hermes:test --json)"
printf '%s\n' "$alias_valid" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "valid"'

future_target="$project/okf/claims/future-target.md"
write_claim "$future_target" future-target 'Future target' 'future target current marker'
future_replacement="$project/okf/claims/future-replacement.md"
write_claim_window "$future_replacement" future-replacement 'Future replacement' 'future replacement marker' '2099-01-01T00:00:00Z' '2199-01-01T00:00:00Z' 'brain_supersedes: okf/claims/future-target.md'
future_output="$($cli --root "$vault" search "$project_id" 'future target current marker' --intent current_state --as-of 2050-01-01T00:00:00Z --explain --limit 10)"
assert_contains "$future_output" $'current\tstable'
assert_not_contains "$future_output" 'historical'

# A scoped procedure/evidence record must never be treated as visible because
# a principal merely shares a substring, and omission of that principal is a
# hard stop rather than an implicit global read.
scoped_procedure="$project/okf/procedures/scoped.md"
write_procedure "$scoped_procedure" scoped 'Scoped procedure' okf/claims/alice.md
sed -i.bak 's/^brain_schema_version: 3$/brain_principal: alice\nbrain_schema_version: 3/' "$scoped_procedure"
rm -f "$scoped_procedure.bak"
if "$cli" --root "$vault" run prepare "$project_id" okf/procedures/scoped.md --task 'scoped' --binding environment=staging >/dev/null 2>&1; then
  fail 'scoped procedure accepted an omitted principal'
fi
if "$cli" --root "$vault" run validate "$project_id" "runs/prepared/$alice_capsule_id.md" --principal alice-bot >/dev/null 2>&1; then
  fail 'scoped capsule accepted a substring principal'
fi
scoped_json="$($cli --root "$vault" run validate "$project_id" "runs/prepared/$alice_capsule_id.md" --principal alice --json)"
printf '%s\n' "$scoped_json" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "valid"'

# A pre-snapshot capsule that points at stateful evidence is not silently
# treated as dependency-free. It must be rejected with an explicit reprepare
# reason, after which a newly prepared capsule is valid again.
legacy_state_procedure="$project/okf/procedures/legacy-state.md"
write_procedure "$legacy_state_procedure" legacy-state 'Legacy state procedure' okf/claims/release-target.md
sed -i.bak 's/^brain_schema_version: 3$/brain_state_key: legacy.release\nbrain_schema_version: 3/' "$legacy_state_procedure"
rm -f "$legacy_state_procedure.bak"
legacy_prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/legacy-state.md --task 'legacy state' --principal hermes:test --binding environment=staging)"
legacy_capsule_id="$(printf '%s\n' "$legacy_prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
legacy_capsule_ref="runs/prepared/$legacy_capsule_id.md"
legacy_capsule="$project/$legacy_capsule_ref"
sed -i.bak -E '/^brain_dependency_(refs|hashes|snapshot_hash_sha256|state):/d' "$legacy_capsule"
rm -f "$legacy_capsule.bak"
legacy_json="$($cli --root "$vault" run validate "$project_id" "$legacy_capsule_ref" --principal hermes:test --json 2>/dev/null || true)"
printf '%s\n' "$legacy_json" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "stale" and value["reason"] == "legacy-state-dependent-capsule-reprepare-required"'
legacy_reprepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/legacy-state.md --task 'legacy state reprepare' --principal hermes:test --binding environment=staging)"
legacy_reprepared_id="$(printf '%s\n' "$legacy_reprepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
legacy_reprepared_json="$($cli --root "$vault" run validate "$project_id" "runs/prepared/$legacy_reprepared_id.md" --principal hermes:test --json)"
printf '%s\n' "$legacy_reprepared_json" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "valid"'

# Branch is a capsule binding: an explicit start branch must agree with the
# prepared binding, just as task and principal do.
branch_prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/release.md --task 'branch checks' --principal hermes:test --binding environment=staging --binding branch=main)"
branch_capsule_id="$(printf '%s\n' "$branch_prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
branch_capsule_ref="runs/prepared/$branch_capsule_id.md"
if "$cli" --root "$vault" run start "$project_id" okf/procedures/release.md --capsule "$branch_capsule_ref" --branch feature --request-id branch-mismatch >/dev/null 2>&1; then
  fail 'capsule accepted a conflicting explicit branch'
fi

# Hold the real project lease while a caller is in the pre-commit window, then
# mutate the procedure/dependency before releasing it. The command must fail
# on its under-lock recheck, not commit using the stale pre-lock observation.
hold_project_lock() {
  local lock_dir="$vault/.locks/project-$project_id.lock" owner_start
  mkdir -p "$vault/.locks"
  (sleep 20) &
  test_lock_pid=$!
  owner_start="$(ps -p "$test_lock_pid" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$owner_start" ] || fail 'test lease holder has no process-start identity'
  kill -0 "$test_lock_pid" 2>/dev/null || fail 'test lease holder is not live'
  mkdir "$lock_dir"
  printf 'pid=%s\nprocess_start=%s\ntimestamp=now\nactor=research-test\ntoken=research-test\n' "$test_lock_pid" "$owner_start" >"$lock_dir/owner"
}
release_project_lock() {
  kill "$test_lock_pid" 2>/dev/null || true
  wait "$test_lock_pid" 2>/dev/null || true
  rm -f "$vault/.locks/project-$project_id.lock/owner"
  rmdir "$vault/.locks/project-$project_id.lock" 2>/dev/null || true
}

write_snapshot_signal_helper() {
  local helper="$1"
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' 'import os'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' 'import subprocess'
    printf '%s\n' 'import sys'
    printf '%s\n' 'real_helper = os.environ["LLM_BRAIN_REAL_OKF_HELPER"]'
    printf '%s\n' 'result = subprocess.run([sys.executable, real_helper, *sys.argv[1:]])'
    printf '%s\n' 'if result.returncode == 0 and len(sys.argv) > 1 and sys.argv[1] == "dependency-snapshot":'
    printf '%s\n' '    Path(os.environ["LLM_BRAIN_SNAPSHOT_SENTINEL"]).touch()'
    printf '%s\n' 'raise SystemExit(result.returncode)'
  } >"$helper"
  chmod 0755 "$helper"
}

wait_for_snapshot_signal() {
  local sentinel="$1" attempt=0
  while [ ! -f "$sentinel" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
      release_project_lock
      fail "pre-lock dependency snapshot signal was not observed: $sentinel"
    fi
    sleep 0.1
  done
}

cp "$procedure" "$fixture/release-procedure.before-race"
snapshot_signal_helper="$fixture/okf-snapshot-signal.py"
write_snapshot_signal_helper "$snapshot_signal_helper"
hold_project_lock
race_start_output="$fixture/race-start.output"
(
  set +e
  LLM_BRAIN_OKF_HELPER="$snapshot_signal_helper" LLM_BRAIN_REAL_OKF_HELPER="$repo_root/lib/okf.py" LLM_BRAIN_SNAPSHOT_SENTINEL="$fixture/race-start.snapshot" LLM_BRAIN_LOCK_WAIT_SECONDS=20 LLM_BRAIN_LOCK_POLL_SECONDS=1 "$cli" --root "$vault" run start "$project_id" okf/procedures/release.md --capsule "$branch_capsule_ref" --request-id lease-race-start >"$race_start_output" 2>&1
  race_rc=$?
  printf '%s\n' "$race_rc" >"$fixture/race-start.status"
) &
race_pid=$!
wait_for_snapshot_signal "$fixture/race-start.snapshot"
if ! kill -0 "$race_pid" 2>/dev/null; then
  release_project_lock
  fail 'run start exited before the under-lock race window'
fi
printf '%s\n' 'procedure changed while start waited for project lease' >>"$procedure"
release_project_lock
wait "$race_pid" 2>/dev/null || true
race_status="$(cat "$fixture/race-start.status")"
[ "$race_status" -ne 0 ] || fail 'run start committed after a lease-window procedure mutation'
cp "$fixture/release-procedure.before-race" "$procedure"

hold_project_lock
race_prepare_output="$fixture/race-prepare.output"
(
  set +e
  LLM_BRAIN_OKF_HELPER="$snapshot_signal_helper" LLM_BRAIN_REAL_OKF_HELPER="$repo_root/lib/okf.py" LLM_BRAIN_SNAPSHOT_SENTINEL="$fixture/race-prepare.snapshot" LLM_BRAIN_LOCK_WAIT_SECONDS=20 LLM_BRAIN_LOCK_POLL_SECONDS=1 "$cli" --root "$vault" run prepare "$project_id" okf/procedures/release.md --task 'lease race prepare' --principal hermes:test --binding environment=staging >"$race_prepare_output" 2>&1
  race_rc=$?
  printf '%s\n' "$race_rc" >"$fixture/race-prepare.status"
) &
race_pid=$!
wait_for_snapshot_signal "$fixture/race-prepare.snapshot"
if ! kill -0 "$race_pid" 2>/dev/null; then
  release_project_lock
  fail 'run prepare exited before the under-lock race window'
fi
printf '%s\n' 'dependency changed while prepare waited for project lease' >>"$project/okf/claims/release-region.md"
release_project_lock
wait "$race_pid" 2>/dev/null || true
race_status="$(cat "$fixture/race-prepare.status")"
[ "$race_status" -ne 0 ] || fail 'run prepare committed after a lease-window dependency mutation'
sed '$d' "$project/okf/claims/release-region.md" >"$fixture/release-region-restored-race.md"
mv "$fixture/release-region-restored-race.md" "$project/okf/claims/release-region.md"

write_claim "$project/okf/claims/lifecycle-root.md" lifecycle-root 'Lifecycle root' 'lifecycle bundle marker' 'brain_derived_from: okf/claims/lifecycle-derived.md'
write_claim "$project/okf/claims/lifecycle-support.md" lifecycle-support 'Lifecycle support' 'supporting lifecycle evidence' 'brain_supports: okf/claims/lifecycle-root.md'
write_claim "$project/okf/claims/lifecycle-conflict.md" lifecycle-conflict 'Lifecycle conflict' 'conflicting lifecycle evidence' 'brain_conflicts: okf/claims/lifecycle-root.md'
write_claim "$project/okf/claims/lifecycle-derived.md" lifecycle-derived 'Lifecycle derived' 'derived lifecycle evidence'
write_claim_sensitivity "$project/okf/claims/lifecycle-secret.md" lifecycle-secret 'Lifecycle secret' 'restricted lifecycle secret' restricted 'brain_supports: okf/claims/lifecycle-root.md'
write_claim "$project/okf/claims/lifecycle-restricted-forward.md" lifecycle-restricted-forward 'Lifecycle restricted forward' 'restricted forward bundle marker' 'brain_supports: okf/claims/lifecycle-secret.md'
write_claim "$project/okf/claims/lifecycle-missing.md" lifecycle-missing 'Lifecycle missing relation' 'incomplete bundle marker' 'brain_supports: okf/claims/does-not-exist.md'
restricted_secret_hash="$(shasum -a 256 "$project/okf/claims/lifecycle-secret.md" | awk '{print $1}')"

lifecycle_output="$($cli --root "$vault" search "$project_id" 'lifecycle bundle marker' --intent current_state --explain --limit 10)"
assert_contains "$lifecycle_output" $'lifecycle_bundle'
assert_not_contains "$lifecycle_output" 'lifecycle-secret.md'
assert_not_contains "$lifecycle_output" 'Lifecycle secret'
assert_not_contains "$lifecycle_output" 'restricted lifecycle secret'
printf '%s\n' "$lifecycle_output" | python3 -c 'import json,sys; lines=sys.stdin.read().splitlines(); header=lines[0].split("\t"); assert header[-1] == "lifecycle_bundle"; assert all(len(line.split("\t")) == len(header) for line in lines[1:] if line); rows={fields[0]: json.loads(fields[-1]) for fields in (line.split("\t") for line in lines[1:] if line)}; assert all("\n" not in field for line in lines for field in line.split("\t")); root=rows["okf/claims/lifecycle-root.md"]; records=root.get("records",[]); assert all(isinstance(record.get("roles"),list) and isinstance(record.get("relations"),list) for record in records); expected={"okf/claims/lifecycle-root.md": {"supports", "conflicts", "derived_by"}, "okf/claims/lifecycle-support.md": {"supported_by"}, "okf/claims/lifecycle-conflict.md": {"conflicted_by"}, "okf/claims/lifecycle-derived.md": {"derived_from"}}; assert all(any(record.get("ref") == ref and wanted.issubset(set(record.get("relations",[]))) for record in records) for ref, wanted in expected.items())'

restricted_forward_output="$($cli --root "$vault" search "$project_id" 'restricted forward bundle marker' --intent evidence --explain --limit 10)"
assert_contains "$restricted_forward_output" 'okf/claims/lifecycle-restricted-forward.md'
assert_not_contains "$restricted_forward_output" 'lifecycle-secret.md'
assert_not_contains "$restricted_forward_output" 'Lifecycle secret'
assert_not_contains "$restricted_forward_output" 'restricted lifecycle secret'
assert_not_contains "$restricted_forward_output" "$restricted_secret_hash"

metadata="$fixture/lifecycle.metadata"
"$cli" --root "$vault" search "$project_id" 'lifecycle bundle marker' --intent evidence --metadata-file "$metadata" --limit 10 >/dev/null
grep -Fq 'lifecycle_bundle_resolution=enabled' "$metadata"
grep -Eq 'lifecycle_bundle_record_count=[1-9][0-9]*' "$metadata" || fail 'lifecycle bundle count missing'

printf '%s\n' 'lifecycle bundle marker' >"$fixture/query.txt"
bridge="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/query.txt" --intent evidence --strategy lexical --budget-tokens 300)"
printf '%s\n' "$bridge" | python3 -c 'import json,sys; value=json.load(sys.stdin); text=json.dumps(value); bundles=value["evidence_bundles"]; assert "lifecycle_bundles" not in value; assert isinstance(bundles,list) and bundles; assert all(isinstance(item,dict) for item in bundles); assert all(isinstance(item.get("records"),list) and isinstance(item.get("incomplete"),bool) for item in bundles); assert all(item.get("visited_count",0) <= 128 and item.get("max_depth",0) <= 8 and len(item.get("records",[])) <= 20 for item in bundles); assert "lifecycle-secret.md" not in text; assert "Lifecycle secret" not in text; assert "restricted lifecycle secret" not in text; assert "sha256" not in text; assert sys.argv[1] not in text' "$restricted_secret_hash"
printf '%s\n' 'restricted forward bundle marker' >"$fixture/restricted-forward-query.txt"
restricted_forward_bridge="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/restricted-forward-query.txt" --intent evidence --strategy lexical --budget-tokens 300)"
printf '%s\n' "$restricted_forward_bridge" | python3 -c 'import json,sys; value=json.load(sys.stdin); text=json.dumps(value); assert "lifecycle-secret.md" not in text; assert "Lifecycle secret" not in text; assert "restricted lifecycle secret" not in text; assert sys.argv[1] not in text' "$restricted_secret_hash"
restricted_forward_pack_result="$($cli --root "$vault" pack build "$project_id" --agent test --task 'restricted forward bundle marker' --intent evidence --budget-tokens 300)"
restricted_forward_pack_file="$(printf '%s\n' "$restricted_forward_pack_result" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$restricted_forward_pack_file" ] || fail 'restricted forward lifecycle pack missing'
restricted_forward_pack="$(cat "$restricted_forward_pack_file")"
assert_not_contains "$restricted_forward_pack" 'lifecycle-secret.md'
assert_not_contains "$restricted_forward_pack" 'Lifecycle secret'
assert_not_contains "$restricted_forward_pack" 'restricted lifecycle secret'
assert_not_contains "$restricted_forward_pack" "$restricted_secret_hash"
pack_result="$($cli --root "$vault" pack build "$project_id" --agent test --task 'lifecycle bundle marker' --intent evidence --budget-tokens 300)"
pack_file="$(printf '%s\n' "$pack_result" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$pack_file" ] || fail 'lifecycle pack missing'
assert_not_contains "$(cat "$pack_file")" 'lifecycle-secret.md'
assert_not_contains "$(cat "$pack_file")" 'Lifecycle secret'
assert_not_contains "$(cat "$pack_file")" 'restricted lifecycle secret'

printf '%s\n' 'incomplete bundle marker' >"$fixture/incomplete-query.txt"
incomplete_bridge="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/incomplete-query.txt" --intent evidence --strategy lexical --budget-tokens 300)"
printf '%s\n' "$incomplete_bridge" | python3 -c 'import json,sys; value=json.load(sys.stdin); text=json.dumps(value); bundles=value["evidence_bundles"]; assert any(item.get("incomplete") for item in bundles); context=value["context_markdown"]; warning=context.lower().find("warning: lifecycle evidence bundle is incomplete"); claim=context.find("### "); assert warning >= 0 and (claim < 0 or warning < claim); assert "does-not-exist" not in text; assert "Lifecycle missing relation" in text'
incomplete_pack_result="$($cli --root "$vault" pack build "$project_id" --agent test --task 'incomplete bundle marker' --intent evidence --budget-tokens 300)"
incomplete_pack_file="$(printf '%s\n' "$incomplete_pack_result" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
[ -f "$incomplete_pack_file" ] || fail 'incomplete lifecycle pack missing'
incomplete_pack="$(cat "$incomplete_pack_file")"
assert_not_contains "$incomplete_pack" 'does-not-exist'
assert_contains "$incomplete_pack" 'Lifecycle missing relation'
warning_pos="$(printf '%s' "$incomplete_pack" | python3 -c 'import sys; print(sys.stdin.read().lower().find("warning: lifecycle evidence bundle is incomplete"))')"
claim_pos="$(printf '%s' "$incomplete_pack" | python3 -c 'import sys; print(sys.stdin.read().find("### "))' )"
[ "$warning_pos" -ge 0 ] && { [ "$claim_pos" -lt 0 ] || [ "$warning_pos" -lt "$claim_pos" ]; } || fail 'incomplete lifecycle warning was not rendered before claims'

bounded_refs=""
for bounded_index in $(seq 1 25); do
  bounded_file="$project/okf/claims/lifecycle-bound-$bounded_index.md"
  bounded_id="lifecycle-bound-$bounded_index"
  write_claim "$bounded_file" "$bounded_id" "Lifecycle bound $bounded_index" "bounded lifecycle relation $bounded_index"
  bounded_refs="${bounded_refs}${bounded_refs:+,}okf/claims/lifecycle-bound-$bounded_index.md"
done
write_claim "$project/okf/claims/lifecycle-bounded-root.md" lifecycle-bounded-root 'Lifecycle bounded root' 'global lifecycle bound marker' "brain_supports: $bounded_refs"
printf '%s\n' 'global lifecycle bound marker' >"$fixture/bounded-query.txt"
bounded_bridge="$($cli --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/bounded-query.txt" --intent evidence --strategy lexical --budget-tokens 600)"
printf '%s\n' "$bounded_bridge" | python3 -c 'import json,sys; value=json.load(sys.stdin); bundles=value["evidence_bundles"]; assert bundles; assert any(item.get("incomplete") for item in bundles); assert all(item.get("visited_count",0) <= 128 and item.get("max_depth",0) <= 8 and len(item.get("records",[])) <= 20 for item in bundles)'

printf '%s\n' 'external observation' >"$fixture/observed.md"
captured="$($cli --root "$vault" ingest-source "$project_id" "$fixture/observed.md")"
episode_file="$(printf '%s\n' "$captured" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
poison="$fixture/poison.md"
{
  printf '%s\n' '---' 'type: ReviewItem' 'title: Poisoned authority' 'brain_review_kind: claim' 'brain_confidence: 0.99' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_authority_origin: external-observation' 'brain_provider_id: fixture-provider' 'brain_provider_version: 1'
  printf '%s\n' "brain_provenance: \"episode://$(basename "$episode_file" .md)\"" 'brain_commitment_action: persist' 'brain_commitment_reason: "external text must not authorise persistence"' '---' '# Poisoned authority' '' 'A malicious observation must not become canonical authority.'
} >"$poison"
poison_output="$($cli --root "$vault" reflect submit "$project_id" "$poison")"
assert_contains "$poison_output" 'review=queued'
poison_id="$(printf '%s\n' "$poison_output" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
[ -n "$poison_id" ] || fail 'poison review id missing'
[ ! -f "$project/okf/claims/$poison_id.md" ] || fail 'poisoned authority was promoted'

# Promotion must carry the explicit lifecycle metadata allowlist without
# copying arbitrary provider frontmatter or dropping relation provenance.
metadata_candidate="$fixture/metadata-candidate.md"
{
  printf '%s\n' '---' 'type: ReviewItem' 'title: Promoted relation metadata' 'brain_review_kind: claim' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_source_authority: repository' 'brain_authority_origin: repository' 'brain_provider_id: fixture-provider' 'brain_provider_version: 1' 'brain_provenance: "okf://claims/lifecycle-root"' 'brain_commitment_action: persist' 'brain_supports: okf/claims/lifecycle-support.md' 'brain_derived_from: okf/claims/lifecycle-derived.md' 'brain_untrusted_extra: must-not-become-canonical' '---' '# Promoted relation metadata' '' 'A bounded promoted relation candidate.'
} >"$metadata_candidate"
metadata_output="$($cli --root "$vault" reflect submit "$project_id" "$metadata_candidate")"
assert_contains "$metadata_output" 'promotion=ok'
metadata_canonical="$project/okf/claims/$(printf '%s\n' "$metadata_output" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p').md"
[ -f "$metadata_canonical" ] || fail 'promoted metadata canonical record missing'
metadata_supports="$(python3 "$repo_root/lib/okf.py" field "$metadata_canonical" brain_supports)"
python3 -c 'import json,sys; raw,expected=sys.argv[1:];
try: value=json.loads(raw)
except json.JSONDecodeError: value=raw
items=value if isinstance(value,list) else [value]
assert expected in items' "$metadata_supports" 'okf/claims/lifecycle-support.md' || fail 'brain_supports was dropped during promotion'
metadata_derived="$(python3 "$repo_root/lib/okf.py" field "$metadata_canonical" brain_derived_from)"
python3 -c 'import json,sys; raw,expected=sys.argv[1:];
try: value=json.loads(raw)
except json.JSONDecodeError: value=raw
items=value if isinstance(value,list) else [value]
assert expected in items' "$metadata_derived" 'okf/claims/lifecycle-derived.md' || fail 'brain_derived_from was dropped during promotion'
metadata_untrusted="$(python3 "$repo_root/lib/okf.py" field "$metadata_canonical" brain_untrusted_extra)"
[ -z "$metadata_untrusted" ] || fail 'arbitrary provider metadata was copied during promotion'

# Poisoning regression: capture/admit an external candidate, explicitly
# approve it as the simulated human mistake, retrieve it through a dependency
# capsule, then retract only the poisoned record and prove unrelated custody
# remains unchanged.
unrelated_before="$(shasum -a 256 "$alias_target" | awk '{print $1}')"
poison_candidate="$fixture/poison-candidate.md"
{
  printf '%s\n' '---' 'type: ReviewItem' 'title: Poison admission marker' 'brain_review_kind: claim' 'brain_confidence: 0.95' 'brain_risk: low' 'brain_sensitivity: internal' 'brain_source_authority: external-observation' 'brain_authority_origin: external-observation' 'brain_provider_id: fixture-provider' 'brain_provider_version: 1' 'brain_valid_from: "2020-01-01T00:00:00Z"' 'brain_valid_to: "2099-01-01T00:00:00Z"' "brain_provenance: \"episode://$(basename "$episode_file" .md)\"" 'brain_commitment_action: persist' '---' '# Poison admission marker' '' 'poison admission marker: this untrusted observation must not become authority without review.'
} >"$poison_candidate"
poison_admission="$(LLM_BRAIN_COMMITMENT_POLICY=enforce "$cli" --root "$vault" reflect submit "$project_id" "$poison_candidate")"
assert_contains "$poison_admission" 'review=queued'
poison_id="$(printf '%s\n' "$poison_admission" | sed -n 's/.*review_id=\([^ ]*\).*/\1/p')"
[ -n "$poison_id" ] || fail 'poison admission review id missing'
[ ! -f "$project/okf/claims/$poison_id.md" ] || fail 'external poison bypassed admission policy'
poison_promoted="$($cli --root "$vault" review decide "$project_id" "$poison_id" approved --actor human:test --reason 'simulated poison admission for repair regression')"
assert_contains "$poison_promoted" 'promotion=ok'
poison_canonical="$project/okf/claims/$poison_id.md"
[ -f "$poison_canonical" ] || fail 'simulated poison was not admitted for repair test'
poison_search="$($cli --root "$vault" search "$project_id" 'poison admission marker' --limit 10 --explain)"
assert_contains "$poison_search" "$poison_id"
poison_procedure="$project/okf/procedures/poison.md"
write_procedure "$poison_procedure" poison 'Poison procedure' "okf/claims/$poison_id.md"
poison_prepared="$($cli --root "$vault" run prepare "$project_id" okf/procedures/poison.md --task 'simulated poison capsule' --principal hermes:test --binding environment=staging)"
poison_capsule_id="$(printf '%s\n' "$poison_prepared" | sed -n 's/.*capsule_id=\([^ ]*\).*/\1/p')"
poison_capsule_ref="runs/prepared/$poison_capsule_id.md"
poison_valid="$($cli --root "$vault" run validate "$project_id" "$poison_capsule_ref" --principal hermes:test --json)"
printf '%s\n' "$poison_valid" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "valid"'
"$cli" --root "$vault" retract "$project_id" "$poison_id" --reason 'repair poisoned memory'
if "$cli" --root "$vault" run validate "$project_id" "$poison_capsule_ref" --principal hermes:test >/dev/null 2>&1; then
  fail 'retracted poison dependency left a valid capsule'
fi
poison_after_repair="$($cli --root "$vault" search "$project_id" 'poison admission marker' --limit 10 --explain)"
assert_not_contains "$poison_after_repair" "$poison_id"
[ "$(shasum -a 256 "$alias_target" | awk '{print $1}')" = "$unrelated_before" ] || fail 'poison repair changed unrelated custody'

printf '%s\n' 'llm-brain research upgrades self-check passed'
