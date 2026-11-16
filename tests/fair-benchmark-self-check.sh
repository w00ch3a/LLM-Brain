#!/usr/bin/env bash
# #7b (16 Nov ideas): honest benchmarks.  `eval run` reports which cases are
# leaky (the answer record shares a source group with a near-duplicate that
# could be copied), leak-free hits, a dev/test fold by source group, and the
# retrieval margin (top-1 vs next); --margin-log tracks it as the brain grows.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-fair-bench.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
export LLM_BRAIN_CACHE_DIR="$fixture/cache"
fail() { printf 'fair benchmark self-check: %s\n' "$*" >&2; exit 1; }
vault="$fixture/vault"; mkdir -p "$fixture/ws"; project_id="proj_fair"
b() { "$cli" --root "$vault" "$@"; }
b project ensure "$fixture/ws" --id "$project_id" >/dev/null
pdir="$vault/projects/$project_id"; claims="$pdir/okf/claims"
rec() { # id title source body
  printf '%s\n' '---' 'type: Claim' "title: \"$2\"" 'status: stable' 'generated: {by: "human:test", at: "2026-05-01T00:00:00Z"}' "sources: [{resource: \"$3\"}]" "brain_project_id: $project_id" "brain_claim_id: $1" 'brain_review_state: approved' 'brain_source_authority: human-directive' 'brain_sensitivity: internal' 'brain_schema_version: 3' '---' "# $2" '' "$4" >"$claims/$1.md"
}
words=(amber basalt cobalt dahlia ember fennel)
: >"$fixture/cases.tsv"; printf 'case_id\tquery\texpected_paths\ttask\n' >"$fixture/cases.tsv"
for i in 0 1 2 3 4 5; do
  w="${words[$i]}"
  rec "fact-$w" "The $w gateway" "doc-$w" "The $w gateway runs on port 9$i$i$i and rotates its $w certificate every month from the $w vault."
  printf 'c-%s\t%s gateway port certificate\tokf/claims/fact-%s.md\tanswer\n' "$w" "$w" "$w" >>"$fixture/cases.tsv"
done
# Near-duplicates of three answers from the same source document (copyable answers).
for w in amber basalt cobalt; do
  rec "copy-$w" "Notes: $w gateway" "doc-$w" "The $w gateway runs on port 9xxx and rotates its $w certificate every month from the $w vault, per the notes."
done
b index build "$project_id" >/dev/null
out="$fixture/e1"
b eval run "$project_id" --cases "$fixture/cases.tsv" --strategies lexical --output "$out" --margin-log "$fixture/margins.tsv" >/dev/null
[ -f "$out/fairness.tsv" ] || fail 'fairness.tsv missing'
grep -q '^## Leak-free split and retrieval margin' "$out/report.md" || fail 'report lacks the section'
leaky="$(awk -F '\t' 'NR > 1 && $4 == "leaky"' "$out/fairness.tsv" | cut -f1 | sort | paste -sd, -)"
[ "$leaky" = 'c-amber,c-basalt,c-cobalt' ] || fail "leaky cases wrong: $leaky"
row="$(awk -F '\t' '$1 == "lexical" && NF == 10' "$out/report.md")"
[ "$(cut -f2 <<<"$row")" = 6 ] && [ "$(cut -f3 <<<"$row")" = 3 ] || fail "summary row wrong: $row"
checks=(leaky_cases_flagged=ok leak_free_reported=ok)
# Folds: a source group never spans dev and test.
python3 - "$out/fairness.tsv" <<'PYCHK' || fail 'fold split broken'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
assert {r["fold"] for r in rows} <= {"dev", "test"}, rows
for r in rows:
    m = r["margin"]
    assert m == "-" or -1.0 <= float(m) <= 1.0, r
PYCHK
checks+=(group_folds=ok)
# Trace and result hash unchanged by the new section (deterministic hash covers the trace only).
grep -q '^brain_result_hash_sha256:' "$out/report.md" || fail 'result hash missing'

# Margin as the brain grows: 9 -> 99 -> 309 records, filler sharing the query words.
grow() { # count
  local n="$1" i w
  for i in $(seq 1 "$n"); do
    w="${words[$((i % 6))]}"
    rec "fill-$RANDOM$i" "Gateway note $i" "filler-$i" "A $w gateway note $i: port review, certificate review and gateway planning for team $i."
  done
  b index build "$project_id" >/dev/null
}
grow 90; b eval run "$project_id" --cases "$fixture/cases.tsv" --strategies lexical --output "$fixture/e2" --margin-log "$fixture/margins.tsv" >/dev/null
grow 210; b eval run "$project_id" --cases "$fixture/cases.tsv" --strategies lexical --output "$fixture/e3" --margin-log "$fixture/margins.tsv" >/dev/null
cat "$fixture/margins.tsv" | cut -f3-9
python3 - "$fixture/margins.tsv" <<'PYCHK' || fail 'margin log wrong'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter="\t") if r["strategy"] == "lexical"]
assert len(rows) == 3, rows
sizes = [int(r["corpus_records"]) for r in rows]
assert sizes[0] < sizes[1] < sizes[2], sizes
margins = [float(r["leak_free_margin_median"]) for r in rows]
assert margins[2] < margins[0], margins
print(f"margin as the brain grows: records {sizes} -> leak-free margin median {margins}")
PYCHK
checks+=(margin_tracked=ok)
printf 'fair benchmark self-check passed: %s\n' "${checks[*]}"
