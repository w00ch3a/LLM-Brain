#!/usr/bin/env bash
# #3 (2 Nov ideas): a preference inside quoted, forwarded or pasted text is
# bound to the person who said it ("reported-by SOURCE"), never saved or
# ranked as the user's own preference.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="${LLM_BRAIN_TEST_CLI:-$repo_root/bin/llm-brain}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-reported.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'reported preference self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_reported"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project="$vault/projects/$project_id"
cat >"$fixture/embedder.sh" <<'EMBEDDER'
#!/usr/bin/env bash
printf 'model: fixture-evidence\ndimensions: 2\nvector: 0 1\n'
EMBEDDER
chmod 755 "$fixture/embedder.sh"
turn() { # file title request observed user assistant
  { printf '%s\n' '---' 'type: HermesTurn' "title: \"$2\"" "brain_request_id: $3" 'brain_principal: "hermes:test"' "brain_observed_at: \"$4\"" '---' "# $2" '' '## User content' '' "$5" '' '## Assistant content' '' "$6"; } >"$1"
  LLM_BRAIN_EMBEDDER="$fixture/embedder.sh" LLM_BRAIN_EMBEDDER_VERSION=fixture "$cli" --root "$vault" bridge capture --source-root "$workspace" --project-id "$project_id" --record "$1" >/dev/null
}
projection_of() { # request id -> claims projection text
  local src; src="$(grep -l "brain_request_id: $1" "$project"/sources/*.md | head -1)"
  local hash; hash="$(basename "$src" | cut -d- -f1)"
  cat "$project/indexes/evidence-claims/${hash}-claims-v3.txt"
}
checks=()

turn "$fixture/own.md" 'Own drink preference' req_own 2026-08-01T00:00:00Z \
  'I prefer green tea in the morning.' 'Noted.'
turn "$fixture/fwd.md" 'Forwarded drinks note' req_fwd 2026-08-02T00:00:00Z \
  $'Can you file this for the offsite?\n---------- Forwarded message ---------\nFrom: Dana Reyes <dana@example.invalid>\nSubject: drinks\n\nI prefer oat milk lattes in the morning.' 'Filed.'
turn "$fixture/paste.md" 'Pasted chat log' req_paste 2026-08-03T00:00:00Z \
  $'Here is a chat I found online:\nUser: I prefer dark roast coffee in the morning.\nAssistant: Noted.' 'Thanks.'
turn "$fixture/quote.md" 'Quoted email' req_quote 2026-08-04T00:00:00Z \
  $'Agreed, see below.\nOn Mon, 3 Aug 2026, Sam Ortiz <sam@example.invalid> wrote:\n> I like iced chai in the morning.' 'Okay.'

own="$(projection_of req_own)"; fwd="$(projection_of req_fwd)"; paste="$(projection_of req_paste)"; quote="$(projection_of req_quote)"
grep -Fq 'subject user relation preference value green tea' <<<"$own" || fail "own preference not bound to the user: $own"
grep -Fq 'subject reported-by Dana Reyes relation preference value oat milk lattes' <<<"$fwd" || fail "forwarded preference not bound to sender: $fwd"
! grep -Fq 'subject user relation preference' <<<"$fwd" || fail "forwarded preference saved as the user's: $fwd"
checks+=(forwarded_bound_to_sender=ok)
grep -Fq 'subject reported-by quoted conversation relation preference value dark roast coffee' <<<"$paste" || fail "pasted chat preference not reported: $paste"
! grep -Fq 'subject user relation preference' <<<"$paste" || fail "pasted chat preference saved as the user's: $paste"
checks+=(nested_chat_reported=ok)
grep -Fq 'subject reported-by Sam Ortiz relation preference value iced chai' <<<"$quote" || fail "quoted email preference not bound to Sam: $quote"
! grep -Fq 'subject user relation preference' <<<"$quote" || fail "quoted preference saved as the user's: $quote"
checks+=(quoted_email_bound_to_author=ok)

# Recall for the user's own preference ranks the user's words first.
printf '%s\n' 'What do I prefer to drink in the morning?' >"$fixture/q.txt"
recall="$("$cli" --root "$vault" bridge recall --source-root "$workspace" --project-id "$project_id" --query-file "$fixture/q.txt" --principal hermes:test --strategy lexical)"
printf '%s\n' "$recall" | python3 -c 'import json,sys; p=json.load(sys.stdin); rows=[r["title"] for r in p["results"] if r["type"] == "HermesTurn"]; assert rows and rows[0] == "Own drink preference", rows; assert "reported-by" in p["context_markdown"] or "Forwarded drinks note" not in rows[:1]' || fail "user's own preference not ranked first: $(printf '%s' "$recall" | python3 -c 'import json,sys; print([r["title"] for r in json.load(sys.stdin)["results"]])')"
checks+=(own_preference_ranked_first=ok)

printf 'reported preference self-check passed: %s\n' "${checks[*]}"
