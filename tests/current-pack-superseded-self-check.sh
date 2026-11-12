#!/usr/bin/env bash
# #2 (2 Nov ideas): current packs carry only the current version of a fact
# (explicit supersession in either reference form, and older values of a
# state key), with a paired-swap check and a "changed on DATE" notice for a
# well-used record that changed recently.  History stays available.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-current-pack.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'current pack self-check: %s\n' "$*" >&2; exit 1; }
ago() { python3 -c "import datetime as d,sys; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

setup() { # name -> sets vault/project vars
  vault="$fixture/$1"; project_id="proj_$1"; mkdir -p "$fixture/ws-$1"
  "$cli" --root "$vault" project ensure "$fixture/ws-$1" --id "$project_id" >/dev/null
  project_dir="$vault/projects/$project_id"; claims="$project_dir/okf/claims"
}
b() { "$cli" --root "$vault" "$@"; }
claim() {
  local id="$1" title="$2" body="$3" at="$4"; shift 4
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' "generated: {by: \"human:test\", at: \"$at\"}" 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $project_id" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
pack() { b pack build "$project_id" --task "$@" | sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
checks=()

# ---- 1. Explicit supersession (list form) + recent-change notice.
setup a
claim port-old 'Staging port' 'The staging deploy listens on port 8080.' "$(ago 60)"
b pack build "$project_id" --task 'staging deploy port' --receipt >/dev/null   # the old value was in use
claim port-new 'Staging port moved' 'The staging deploy listens on port 8443.' "$(ago 2)" 'brain_supersedes: ["okf/claims/port-old.md"]'
p="$(pack 'staging deploy port')"
grep -Fq 'port 8443' "$p" || fail 'current value missing'
! grep -Fq 'Expansion: <code>okf/claims/port-old.md</code>' "$p" || fail "superseded version rendered in a current pack: $(cat "$p")"
grep -Fq '## Changed recently' "$p" || fail "no change notice: $(cat "$p")"
grep -Eq 'Changed on [0-9-]+: was "The staging deploy listens on port 8080\.".*now "The staging deploy listens on port 8443\."' "$p" || fail "notice text wrong: $(grep -A2 'Changed recently' "$p")"
h="$(pack 'staging deploy port' --historical)"
grep -Fq 'Expansion: <code>okf/claims/port-old.md</code>' "$h" || fail 'history pack lost the old version'
checks+=(superseded_list_form_excluded=ok change_notice=ok history_keeps_old=ok)

# ---- 2. Paired swap: same two texts, roles swapped -> the other one wins.
setup swap
claim port-old 'Staging port' 'The staging deploy listens on port 8443.' "$(ago 60)"
claim port-new 'Staging port moved' 'The staging deploy listens on port 8080.' "$(ago 2)" 'brain_supersedes: ["okf/claims/port-old.md"]'
p="$(pack 'staging deploy port')"
grep -Fq 'port 8080' "$p" && ! grep -Fq 'port 8443' "$p" || fail "paired swap: lifecycle, not content, must pick the value: $(cat "$p")"
! grep -Fq '## Changed recently' "$p" || fail 'notice shown for a version nobody used'
checks+=(paired_swap=ok unused_change_no_notice=ok)

# ---- 3. Older value of a state key.
setup key
claim cache-old 'Cache size' 'The build cache holds 20 GB.' "$(ago 90)" 'brain_state_key: build.cache'
claim cache-new 'Cache size now' 'The build cache holds 50 GB.' "$(ago 40)" 'brain_state_key: build.cache'
p="$(pack 'build cache size')"
grep -Fq '50 GB' "$p" && ! grep -Fq '20 GB' "$p" || fail "older state value in current pack: $(cat "$p")"
grep -Fq 'brain_superseded_omitted: 1' "$p" || fail 'omission not recorded in metadata'
a="$(pack 'build cache size' --as-of "$(ago 60)")"
grep -Fq '20 GB' "$a" || fail 'as-of pack lost the value in force then'
o="$(LLM_BRAIN_PACK_CURRENT_ONLY=0 b pack build "$project_id" --task 'build cache size' --agent optout | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq '20 GB' "$o" || fail 'LLM_BRAIN_PACK_CURRENT_ONLY=0 did not restore the earlier pack'
checks+=(older_state_value_excluded=ok as_of_keeps_old=ok opt_out=ok)

printf 'current pack self-check passed: %s\n' "${checks[*]}"
