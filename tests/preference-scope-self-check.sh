#!/usr/bin/env bash
# 26 Oct idea 5: optional "applies when" scope on preference records.
#   brain_applies_when: "project=ID; host=a,b; task=t"
# Packs, briefs (and the session-start hook) and Hermes bridge recall surface
# a scoped record only inside its scope; plain search lists it with an
# "[out of scope: ...]" mark. Unscoped records behave as before.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
py="${LLM_BRAIN_OKF_PYTHON:-python3}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-scope.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'preference scope self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; pid="proj_scope"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$pid" >/dev/null
pdir="$vault/projects/$pid"; claims="$pdir/okf/claims"; mkdir -p "$claims"
unset LLM_BRAIN_HOST LLM_BRAIN_TASK_TYPE MEMTHENA_HOST
b() { (cd "$workspace" && "$cli" --root "$vault" "$@"); }
pack_file() { sed -n 's/.*file=\([^ ]*\).*/\1/p'; }
pref() { # id title body [extra frontmatter...]
  local id="$1" title="$2" body="$3"; shift 3
  {
    printf '%s\n' '---' 'type: Claim' "title: \"$title\"" 'status: stable'
    printf '%s\n' 'generated: {by: "human:test", at: "2026-10-01T00:00:00Z"}' 'sources: [{resource: "self-check fixture"}]'
    printf '%s\n' "brain_project_id: $pid" "brain_claim_id: $id" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal'
    while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
    printf '%s\n' 'brain_schema_version: 3' '---' "# $title" '' "$body"
  } >"$claims/$id.md"
}
pref style-plain 'Indent style preference' 'Indent style preference: use four spaces for indentation.'
pref style-hermes 'Indent style preference for hermes' 'Indent style preference: use tabs for indentation in hermes sessions.' 'brain_applies_when: "host=hermes"'
pref style-review 'Indent style preference for review' 'Indent style preference: flag mixed indentation during code review tasks.' "brain_applies_when: \"project=$pid; host=codex,claude-code; task=review\""
pref style-odd 'Indent style preference odd scope' 'Indent style preference: odd scope still shows.' 'brain_applies_when: "planet=mars"'
pref nodeploy 'No Friday deploys' 'Never deploy on Fridays in hermes.' 'brain_constraint: prohibition' 'brain_applies_when: "host=hermes"'

b index build "$pid" >/dev/null
task='indent style preference indentation'
has() { grep -Fq "$2" "$1"; }

# Scope FAILS OPEN: a caller that has not identified itself sees everything.
generic="$(b pack build "$pid" --task "$task" 2>"$fixture/generic.err" | pack_file)"
has "$generic" 'four spaces' || fail 'unscoped record missing from a generic pack'
has "$generic" 'tabs for indentation' || fail 'unknown host hid a host=hermes record (must fail open)'
has "$generic" 'mixed indentation' || fail 'unknown host/task hid the review-scoped record (must fail open)'
has "$generic" 'odd scope' || fail 'malformed/unknown-key scope hid a record (must fail open)'
grep -q '^memthena: warning: malformed brain_applies_when' "$fixture/generic.err" || fail "no memthena: warning for the malformed scope: $(cat "$fixture/generic.err")"
! grep -q '^brain_applies_when_hidden:' "$generic" || fail 'generic pack reports hidden records'

# MCP server with no LLM_BRAIN_HOST (pack built as --agent mcp) sees host-scoped records.
mcp="$(b pack build "$pid" --task "$task" --agent mcp 2>/dev/null | pack_file)"
has "$mcp" 'tabs for indentation' || fail 'MCP caller with no host lost the host=hermes record'
has "$mcp" 'mixed indentation' || fail 'MCP caller with no host lost the review record'
grep -Fq -- '"--agent", "mcp"' "$repo_root/lib/mcp_server.py" || fail 'MCP pack no longer builds as agent mcp'

hermes="$(b pack build "$pid" --task "$task" --agent hermes | pack_file)"
has "$hermes" 'tabs for indentation' || fail 'host=hermes record missing from a hermes pack'
has "$hermes" 'four spaces' || fail 'unscoped record missing from a hermes pack'
! has "$hermes" 'mixed indentation' || fail 'review record leaked into a hermes pack'

# A known, different host hides.
codex="$(b pack build "$pid" --task "$task" --agent codex | pack_file)"
! has "$codex" 'tabs for indentation' || fail 'host=hermes record shown to known host codex'
has "$codex" 'mixed indentation' || fail 'task=review record hidden when no task type was given'
codexdoc="$(b pack build "$pid" --task "$task" --agent codex --task-type docs | pack_file)"
! has "$codexdoc" 'mixed indentation' || fail 'task=review record shown for known task type docs'
review="$(b pack build "$pid" --task "$task" --agent codex --task-type review | pack_file)"
has "$review" 'mixed indentation' || fail 'review record missing for host=codex task=review'
! has "$review" 'tabs for indentation' || fail 'hermes record leaked into a codex review pack'
envreview="$(LLM_BRAIN_TASK_TYPE=Review b pack build "$pid" --task "$task" --host claude-code | pack_file)"
has "$envreview" 'mixed indentation' || fail 'LLM_BRAIN_TASK_TYPE / --host / case-insensitive match failed'

# Standing constraints in packs obey the same scope.
cg="$(b pack build "$pid" --task 'deploy fridays' --turn 8 | pack_file)"
has "$cg" 'Never deploy on Fridays' || fail 'scoped standing constraint hidden from an unidentified caller'
cc="$(b pack build "$pid" --task 'deploy fridays' --turn 8 --host codex | pack_file)"
! has "$cc" 'Never deploy on Fridays' || fail 'host=hermes standing constraint leaked to host=codex'
ch="$(b pack build "$pid" --task 'deploy fridays' --turn 8 --host hermes | pack_file)"
has "$ch" 'Never deploy on Fridays' || fail 'scoped standing constraint missing for host=hermes'

# Hermes bridge recall: the plugin exports LLM_BRAIN_HOST=hermes.
printf '%s\n' "$task" >"$fixture/q.txt"
recall() { b bridge recall --source-root "$workspace" --project-id "$pid" --query-file "$fixture/q.txt" "$@" | "$py" -c 'import json,sys; d=json.load(sys.stdin); print(d.get("context_markdown","")); print("\n".join(str(r) for r in d.get("results",[])))'; }
r_plain="$(recall 2>/dev/null)"
grep -Fq 'style-hermes' <<<"$r_plain" || fail 'bridge recall without a host hid a host-scoped record (must fail open)'
r_codex="$(LLM_BRAIN_HOST=codex recall)"
! grep -Fq 'style-hermes' <<<"$r_codex" || fail 'bridge recall as codex surfaced the hermes record'
r_hermes="$(LLM_BRAIN_HOST=hermes recall)"
grep -Fq 'style-hermes' <<<"$r_hermes" || fail "bridge recall as hermes lost the hermes record: $r_hermes"
grep -Fq 'LLM_BRAIN_HOST"] = "hermes"' "$repo_root/integrations/hermes/llm-brain/__init__.py" || fail 'Hermes plugin does not export LLM_BRAIN_HOST'

# Brief (injected at session start) obeys the same scope.
bg="$(b brief "$pid" --max-bytes 16000 2>/dev/null)"
grep -Fq 'four spaces' <<<"$bg" || fail 'unscoped record missing from a generic brief'
grep -Fq 'tabs for indentation' <<<"$bg" || fail 'host=hermes record hidden from an unidentified brief'
grep -Fq 'odd scope' <<<"$bg" || fail 'malformed scope hidden from a brief'
! grep -Fq 'scoped to another project' <<<"$bg" || fail "generic brief claims hidden records: $bg"
bc="$(b brief "$pid" --max-bytes 16000 --host codex 2>/dev/null)"
! grep -Fq 'tabs for indentation' <<<"$bc" || fail 'host=hermes record leaked into a codex brief'
grep -Fq '(2 record(s) scoped to another project, host or task omitted.)' <<<"$bc" || fail "codex brief hidden note missing: $bc"
bh="$(LLM_BRAIN_HOST=hermes b brief "$pid" --max-bytes 16000)"
grep -Fq 'tabs for indentation' <<<"$bh" || fail 'host=hermes record missing from a hermes brief'
! grep -Fq 'mixed indentation' <<<"$bh" || fail 'review record leaked into a hermes brief'
br="$(b brief "$pid" --max-bytes 16000 --host codex --task-type review)"
grep -Fq 'mixed indentation' <<<"$br" || fail 'brief --host/--task-type did not admit the review record'
bj="$(b brief "$pid" --json --max-bytes 16000 --host codex 2>/dev/null)"
"$py" -c 'import json,sys; assert json.loads(sys.argv[1])["scope_hidden"] == 2' "$bj" || fail 'brief --json lacks scope_hidden'
if b brief "$pid" --host "$(printf 'a\nb')" >/dev/null 2>"$fixture/err"; then fail 'multi-line --host accepted'; fi
grep -q '^memthena: ' "$fixture/err" || fail 'brief --host error lacks memthena: prefix'
# The session-start hook passes its agent as the host (default claude-code).
hook() { (cd "$workspace" && env -u LLM_BRAIN_HOST -u MEMTHENA_HOST XDG_CACHE_HOME="$fixture/cache" XDG_STATE_HOME="$fixture/state" LLM_BRAIN_ROOT="$vault" LLM_BRAIN_SESSION_BRIEF_BYTES=16000 "$@" sh "$repo_root/hooks/session-start.sh"); }
h_default="$(hook)"
grep -Fq 'four spaces' <<<"$h_default" || fail "session-start brief missing: $h_default"
! grep -Fq 'tabs for indentation' <<<"$h_default" || fail 'host=hermes record leaked into the claude-code session brief'
h_hermes="$(hook LLM_BRAIN_AGENT=hermes)"
grep -Fq 'tabs for indentation' <<<"$h_hermes" || fail 'session-start as hermes lost the hermes record'
h_review="$(hook LLM_BRAIN_TASK_TYPE=review)"
grep -Fq 'mixed indentation' <<<"$h_review" || fail 'session-start (claude-code, task=review) lost the review record'

# Plain search is an explicit lookup: scoped records stay listed, marked when
# outside the current host/task context.
sg="$(b search "$pid" 'indent style preference' 2>/dev/null)"
grep -Fq 'okf/claims/style-hermes.md' <<<"$sg" || fail 'search hid a scoped record'
! grep -F 'okf/claims/style-hermes.md' <<<"$sg" | grep -Fq 'out of scope' || fail "search marked the hermes record for an unknown host: $sg"
! grep -F 'okf/claims/style-odd.md' <<<"$sg" | grep -Fq 'out of scope' || fail 'search marked the malformed-scope record'
sc="$(LLM_BRAIN_HOST=codex b search "$pid" 'indent style preference' 2>/dev/null)"
grep -F 'okf/claims/style-hermes.md' <<<"$sc" | grep -Fq '[out of scope: host=hermes]' || fail "search did not mark the hermes record for host=codex: $sc"
! grep -F 'okf/claims/style-plain.md' <<<"$sg" | grep -Fq 'out of scope' || fail 'search marked an unscoped record'
sh_="$(LLM_BRAIN_HOST=hermes b search "$pid" 'indent style preference')"
! grep -F 'okf/claims/style-hermes.md' <<<"$sh_" | grep -Fq 'out of scope' || fail 'search marked an in-scope record for host=hermes'
grep -F 'okf/claims/style-review.md' <<<"$sh_" | grep -Fq '[out of scope: project=' || fail 'search lost the review mark for host=hermes'

# Scoped records stay valid OKF (the field is optional and additive).
lint_out="$(b lint --project "$pid" 2>&1 || true)"
! grep -i 'applies_when' <<<"$lint_out" | grep -qi 'error' || fail "lint rejects brain_applies_when: $lint_out"

# Promotion keeps the field.
grep -q 'brain_applicability brain_applies_when' "$cli" || fail 'promote drops brain_applies_when'
printf 'preference-scope=ok\n'
