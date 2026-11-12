#!/usr/bin/env bash
# #12: a cue is assessed ACT / WAIT against the intention's condition, and a
# fire-once intention retires only when the action actually went out.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-intent.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'intention-assess self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; ws="$fixture/ws"; pid=proj_intent; mkdir -p "$ws"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$ws" --id "$pid" >/dev/null
idof() { sed -n 's/.*intention_id=\([^ ]*\).*/\1/p'; }
packof() { sed -n 's/.*file=\([^ ]*\).*/\1/p'; }

send="$(b intention add "$pid" --action 'Send the invoice to Acme' --trigger keyword:invoice --once | idof)"
gated="$(b intention add "$pid" --action 'Publish the release notes' --trigger keyword:release --condition after:2099-01-01T00:00:00Z | idof)"

# 1. A cue that defers: WAIT, not ACT, and nothing is marked proposed.
pack="$(b pack build "$pid" --task 'the invoice is not yet approved; hold it' | packof)"
grep -q '^## Intentions on hold' "$pack" || fail "no on-hold section: $(cat "$pack")"
! grep -q '^## Due Intentions' "$pack" || fail 'a deferring cue was listed as act-now'
grep -q "Send the invoice to Acme.*wait: cue says 'not yet'" "$pack" || fail 'wait reason missing'
! grep -q brain_last_surfaced_at "$vault/projects/$pid/intentions/$send.md" || fail 'a WAIT marked the intention proposed'
echo "defer_cue_waits=ok"

# 2. Declared condition not met: WAIT even though the keyword appeared.
pack="$(b pack build "$pid" --task 'draft the release announcement' | packof)"
grep -q "Publish the release notes.*wait: condition after:2099" "$pack" || fail 'unmet condition did not wait'
[ -z "$(b intention list "$pid" --due --task 'draft the release announcement' | tail -n +2)" ] || fail 'unmet condition listed as due'
echo "unmet_condition_waits=ok"

# 3. The real cue: ACT, marked proposed (not retired).
pack="$(b pack build "$pid" --task 'send the invoice to Acme today' | packof)"
grep -q '^## Due Intentions' "$pack" && grep -q 'Send the invoice to Acme' "$pack" || fail 'real cue did not act'
grep -q '^brain_last_surfaced_at:' "$vault/projects/$pid/intentions/$send.md" || fail 'act did not record the proposal'
grep -q 'brain_intention_status: open' "$vault/projects/$pid/intentions/$send.md" || fail 'proposal retired the intention early'
echo "real_cue_acts=ok"

# 4. Proposed but not confirmed: still listed (no missed action), flagged as
#    already proposed (no blind repeat).
pack="$(b pack build "$pid" --task 'invoice follow-up' | packof)"
grep -q 'Already proposed at .*do not repeat it' "$pack" || fail 'second surfacing lacks the already-proposed guard'
[ "$(grep -c 'intention-proposed' "$vault/projects/$pid/audit.v2.tsv")" = 1 ] || fail 'proposal recorded more than once'
echo "proposed_not_retired=ok"

# 5. Retired only when the action went out.
b intention done "$pid" "$send" --reason 'invoice emailed' --evidence 'mail:fixture-123' >/dev/null
grep -q '^brain_done_evidence: "mail:fixture-123"' "$vault/projects/$pid/intentions/$send.md" || fail 'done evidence not kept'
pack="$(b pack build "$pid" --task 'send the invoice to Acme today' | packof)"
! grep -q 'Send the invoice to Acme' <(awk '/^## Due Intentions/,/^$/' "$pack") || fail 'done intention still due'
echo "done_retires=ok"
echo "intention-assess self-check passed"
