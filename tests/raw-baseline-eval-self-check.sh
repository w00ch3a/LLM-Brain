#!/usr/bin/env bash
# Idea 6: eval raw-history baseline arms (raw-bm25, raw-embed).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-raw-baseline.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_raw_baseline"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
printf 'The billing deploy window is Tuesday at noon after the freeze.\n' >"$fixture/billing.md"
printf 'The coffee machine on floor three is broken again.\n' >"$fixture/coffee.md"
printf 'Lunch roster rotates every Friday.\n' >"$fixture/lunch.md"
for f in billing coffee lunch; do "$cli" --root "$vault" ingest-source "$project_id" "$fixture/$f.md" >/dev/null; done
project_dir="$vault/projects/$project_id"
billing_rel="$(cd "$project_dir" && find sources -type f -name '*-billing-md.md' | head -n 1)"
[ -n "$billing_rel" ]

cat >"$fixture/embedder.sh" <<'EMBEDDER'
#!/usr/bin/env bash
# Deterministic toy embedder: dimension 1 = mentions billing/deploy.
text="$(cat)"
case "$text" in *billing*|*deploy*) v='1 0' ;; *) v='0 1' ;; esac
printf 'model: raw-fixture\ndimensions: 2\nvector: %s\n' "$v"
EMBEDDER
chmod 755 "$fixture/embedder.sh"
"$cli" --root "$vault" index build "$project_id" --embedder "$fixture/embedder.sh" >/dev/null

printf 'case_id\tquery\texpected_paths\ttask\nbilling\tbilling deploy window\t%s\twhen is the billing deploy\n' "$billing_rel" >"$fixture/cases.tsv"

# Helper ranks the right raw file first.
top="$(LLM_BRAIN_ROOT="$vault" python3 "$repo_root/lib/memory_signals.py" raw-baseline --project-dir "$project_dir" --query 'billing deploy window' --mode bm25 | head -n 1 | cut -f1)"
[ "$top" = "$billing_rel" ] || { echo "raw-bm25 top=$top" >&2; exit 1; }

run="$("$cli" --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies none,lexical,raw-bm25,raw-embed --query-embedder "$fixture/embedder.sh" --output "$fixture/out-raw")"
grep -Fq 'eval=' <<<"$run"
report="$fixture/out-raw/report.md"
trace="$fixture/out-raw/trace.tsv"
grep -Fq '## Raw-history baseline' "$report"
grep -Fq $'billing\traw-bm25\traw-bm25\tfalse' "$trace"
grep -Fq $'billing\traw-embed\traw-embed\tfalse' "$trace"
awk -F '\t' '$2 == "raw-bm25" && $9 == "true" { ok = 1 } END { exit !ok }' "$trace"
awk -F '\t' '$2 == "raw-embed" && $9 == "true" { ok = 1 } END { exit !ok }' "$trace"
# lexical row is judged against the raw baseline (1 hit).
grep -Eq $'^lexical\t[0-9]+\t1\t[0-9]+\t[0-9]+\t(beats|ties|loses-to)-baseline$' "$report"
! grep -Eq $'^none\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t' <(sed -n '/## Raw-history baseline/,/## Artefacts/p' "$report")
# The embed cache is derived and must not survive in the output.
[ ! -e "$fixture/out-raw/raw-embed-cache" ]

# raw-embed with no embedder available degrades instead of failing.
"$cli" --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies raw-embed --output "$fixture/out-noembed" >/dev/null
if [ ! -f "$repo_root/models/lbembed.py" ] || [ ! -f "$repo_root/models/lbembed-v2-int4.bin" ]; then
  grep -Fq $'raw-embed\traw-embed-unavailable\ttrue' "$fixture/out-noembed/trace.tsv"
fi

# Default report (no raw-* arm requested) is unchanged: no baseline section.
"$cli" --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies none,lexical --output "$fixture/out-default" >/dev/null
! grep -Fq 'Raw-history baseline' "$fixture/out-default/report.md"
! grep -Fq 'raw-' "$fixture/out-default/trace.tsv"

# Unknown raw arm is rejected.
if "$cli" --root "$vault" eval run "$project_id" --cases "$fixture/cases.tsv" --strategies raw-nope --output "$fixture/out-bad" >/dev/null 2>&1; then exit 1; fi

printf 'raw-baseline-eval-self-check=ok\n'
