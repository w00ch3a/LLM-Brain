#!/usr/bin/env bash
# Self-check for the 0.9 ideas: access-recency rerank (#1), named-gate
# abstention (#2), brief compaction (#3), standing-constraint re-injection
# (#4), intention aftereffects (#5), folder summaries (#6), progressive state
# (#7), cascading invalidation (#8), sufficiency-gated recall (#9), working
# memory (#10), the intention board/observe/patches (#11) and label lineage.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-lineage.XXXXXX")"
trap '[ "${LLM_BRAIN_KEEP_TEST_FIXTURE:-0}" = 1 ] || rm -rf "$fixture"' EXIT
fail() { printf 'lineage ideas self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"
workspace="$fixture/workspace"
project_id="proj_lineage_self_check"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"
claims="$project_dir/okf/claims"
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

# Research-style decision tree: a dataset choice revised twice, a finding
# derived from the first choice, and an analysis that depends on that finding.
claim dataset-v1 'Dataset choice: CensusA' 'Use the CensusA 2019 extract for the wage study.' 2026-01-01T00:00:00Z 'brain_state_key: study.dataset'
claim dataset-v2 'Dataset choice: CensusB' 'Use the CensusB 2021 extract for the wage study; CensusA undercounts.' 2026-02-01T00:00:00Z 'brain_state_key: study.dataset' 'brain_supersedes: ["okf/claims/dataset-v1.md"]'
claim finding-gap 'Wage gap finding' 'The wage gap is 14 percent on the chosen extract.' 2026-01-10T00:00:00Z 'brain_derived_from: ["okf/claims/dataset-v1.md"]'
claim analysis 'Regional analysis' 'Regional wage analysis builds on the wage gap finding.' 2026-01-12T00:00:00Z 'brain_depends_on: ["okf/claims/finding-gap.md"]'
claim method 'Method note' 'We weight by population and cite every extract.' 2026-01-05T00:00:00Z 'brain_supports: ["okf/claims/dataset-v1.md"]'
claim never-push 'Never force-push main' 'Do not force-push the main branch.' 2026-01-02T00:00:00Z 'brain_constraint: prohibition'
claim dataset-v3 'Dataset choice: CensusC' 'Use the CensusC 2024 extract for the wage study.' 2026-03-01T00:00:00Z 'brain_state_key: study.dataset'

# ---- #8 cascading invalidation: implicit (same state key) and topological.
plan="$(b invalidate preview "$project_id" --from okf/claims/dataset-v2.md)"
awk -F '\t' '$1 == "okf/claims/dataset-v1.md" && $2 == "REPLACE" { f=1 } END { exit !f }' <<<"$plan" || fail "v1 not REPLACE: $plan"
awk -F '\t' '$1 == "okf/claims/finding-gap.md" && $2 == "STALE" { f=1 } END { exit !f }' <<<"$plan" || fail "derived finding not STALE: $plan"
awk -F '\t' '$1 == "okf/claims/analysis.md" && $2 == "STALE" && $3 == 2 { f=1 } END { exit !f }' <<<"$plan" || fail "dependent analysis not cascaded: $plan"
awk -F '\t' '$1 == "okf/claims/method.md" && $2 == "KEEP" { f=1 } END { exit !f }' <<<"$plan" || fail "independently supported record not KEEP: $plan"
plan3="$(b invalidate preview "$project_id" --from okf/claims/dataset-v3.md)"
awk -F '\t' '$1 == "okf/claims/dataset-v2.md" && $2 == "REPLACE" { f=1 } END { exit !f }' <<<"$plan3" || fail "implicit replacement (no explicit supersedes) missed: $plan3"
before="$(cd "$claims" && cat ./*.md | shasum -a 256)"
[ ! -e "$project_dir/lineage/labels.tsv" ] || fail 'preview wrote labels'
b invalidate apply "$project_id" --from okf/claims/dataset-v3.md --reason 'CensusC adopted' >/dev/null
[ "$before" = "$(cd "$claims" && cat ./*.md | shasum -a 256)" ] || fail 'invalidate apply edited canonical records'
grep -Fq 'outcome:REPLACE' "$project_dir/lineage/labels.tsv" || fail 'outcome label missing'
grep -Fq 'invalidate-apply' "$project_dir/audit.v2.tsv" || fail 'invalidate apply not audited'

# ---- labels: validation, idempotence, append-only removal, hash chain.
b label add "$project_id" okf/claims/dataset-v2.md decision-point:dataset --reason 'dataset decision' >/dev/null
b label add "$project_id" okf/claims/dataset-v2.md decision-point:dataset --reason 'again' | grep -Fq 'label=unchanged' || fail 'label not idempotent'
b label add "$project_id" okf/claims/dataset-v1.md 'Bad Label' --reason x >/dev/null 2>&1 && fail 'invalid label accepted'
b label add "$project_id" okf/claims/dataset-v1.md outcome:MAYBE --reason x >/dev/null 2>&1 && fail 'invalid outcome accepted'
b label add "$project_id" okf/claims/missing.md retired --reason x >/dev/null 2>&1 && fail 'label on missing record accepted'
b label add "$project_id" okf/claims/method.md retired --reason 'method replaced' >/dev/null
b label remove "$project_id" okf/claims/method.md retired --reason 'mistake' >/dev/null
grep -c $'\tunlabel\t' "$project_dir/lineage/labels.tsv" | grep -qx 1 || fail 'unlabel event missing'
grep -Fq $'\tlabel\tokf/claims/method.md\tretired' "$project_dir/lineage/labels.tsv" || fail 'removed label erased from history'
labels_json="$(b label list "$project_id" --json)"
grep -Fq '"ledger_verified":true' <<<"$labels_json" || fail 'ledger hash chain not verified'
! grep -Fq '"label":"retired"' <<<"$labels_json" || fail 'removed label still active'
grep -Fq 'superseded-by' <<<"$(b label list "$project_id" okf/claims/dataset-v1.md)" || fail 'derived supersession label missing'
cp "$project_dir/lineage/labels.tsv" "$fixture/ledger.bak"
sed -i.tmp 's/dataset decision/tampered/' "$project_dir/lineage/labels.tsv"
b label add "$project_id" okf/claims/analysis.md topic:wages --reason x >/dev/null 2>&1 && fail 'append accepted on a broken chain'
cp "$fixture/ledger.bak" "$project_dir/lineage/labels.tsv"

# ---- lineage show: tree, current head and change points.
lineage="$(b lineage show "$project_id" --decision dataset)"
grep -Fq 'Dataset choice: CensusA' <<<"$lineage" || fail "lineage lacks the original choice: $lineage"
grep -Fq '└─ Dataset choice: CensusB' <<<"$lineage" || fail "lineage tree lacks the revision: $lineage"
grep -Eq '^ \* .*supersedes  okf/claims/dataset-v2.md' <<<"$lineage" || fail "supersession not marked as a change point: $lineage"
grep -Fq 'Current: okf/claims/dataset-v3.md' <<<"$lineage" || fail "current head wrong: $lineage"
json="$(b lineage show "$project_id" --topic 'dataset choice' --json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["changes"]>=2 and "okf/claims/finding-gap.md" in d["records"], d' "$json" || fail 'topic lineage json'
grep -Fq 'lineage=empty' <<<"$(b lineage show "$project_id" --topic 'nothing matches here')" || fail 'empty lineage'

# ---- label filters on search and packs.
grep -Fq okf/claims/finding-gap.md <<<"$(b search "$project_id" 'wage gap finding')" || fail 'baseline search lost the finding'
! grep -Fq okf/claims/finding-gap.md <<<"$(b search "$project_id" 'wage gap finding' --without-label outcome:STALE)" || fail '--without-label did not filter'
only="$(b search "$project_id" 'wage' --label decision-point --metadata-file "$fixture/label.meta" | tail -n +2 | cut -f1)"
[ "$only" = okf/claims/dataset-v2.md ] || fail "--label filter returned: $only"
grep -Fq 'label_filtered_count=' "$fixture/label.meta" || fail 'label filter metadata missing'
pack="$(b pack build "$project_id" --task 'wage study dataset' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq '## Lineage Labels' "$pack" || fail 'pack lacks lineage labels'

# ---- #2 named gates.
gates="$(b gates "$project_id" 'CensusA undercount' --json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["matched"]>=1 and d["eligible"]>=1, d' "$gates" || fail "gates json: $gates"
grep -Fq 'primary_gate=relevance' <<<"$(b gates "$project_id" 'zebra quasar')" || fail 'relevance gate not named'
claim draft 'Unapproved telescope note' 'The telescope mirror is 4 metres.' 2026-01-01T00:00:00Z
sed -i.tmp 's/brain_review_state: approved/brain_review_state: proposed/' "$claims/draft.md"; rm -f "$claims/draft.md.tmp"
b search "$project_id" 'telescope mirror' --metadata-file "$fixture/gate.meta" >/dev/null
grep -Fxq 'abstain_gate=validity' "$fixture/gate.meta" || fail "empty search did not name the validity gate: $(cat "$fixture/gate.meta")"
pack="$(b pack build "$project_id" --task 'telescope mirror' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Recall Gates — nothing selected (primary gate: validity)' "$pack" || fail 'pack lacks recall gates'

# ---- #1 recency rerank: opt-in, reorders, never filters.
default_order="$(b search "$project_id" 'dataset extract' --limit 10 | tail -n +2 | cut -f1)"
mkdir -p "$project_dir/audit"
printf '{"recorded_at":"2026-10-11T00:00:00Z","selected":["okf/claims/dataset-v1.md"],"rendered_selection":[]}\n' >>"$project_dir/audit/retrieval-receipts.jsonl"
[ "$default_order" = "$(b search "$project_id" 'dataset extract' --limit 10 | tail -n +2 | cut -f1)" ] || fail 'recency changed default ranking'
boosted="$(b search "$project_id" 'dataset extract' --limit 10 --recency-boost --historical --metadata-file "$fixture/rec.meta" | tail -n +2 | cut -f1)"
grep -Fxq 'recency_boost=enabled' "$fixture/rec.meta" || fail 'recency metadata missing'
[ "$(printf '%s\n' "$boosted" | wc -l)" -ge "$(printf '%s\n' "$default_order" | wc -l)" ] || fail 'recency filtered records'
ranked="$fixture/ranked.tsv"
printf 'okf/claims/dataset-v2.md\t1.0\t\t\t\t\nokf/claims/dataset-v1.md\t0.9\t\t\t\t\n' >"$ranked"
first="$(python3 "$repo_root/lib/memory_lineage.py" recency --project-dir "$project_dir" --ranked "$ranked" --now 2026-10-12T00:00:00Z | head -n1 | cut -f1)"
[ "$first" = okf/claims/dataset-v1.md ] || fail "recently used record did not float: $first"
first="$(python3 "$repo_root/lib/memory_lineage.py" recency --project-dir "$project_dir" --ranked "$ranked" --now 2027-10-12T00:00:00Z | head -n1 | cut -f1)"
[ "$first" = okf/claims/dataset-v2.md ] || fail 'old use did not decay to the floor'

# ---- #9 sufficiency loop.
suff="$(b recall-check "$project_id" 'CensusC extract wage' --json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["stop"]=="sufficient" and d["steps"][-1]["sufficiency"]>=0.8 and d["steps"][-1]["missing"]==[], d' "$suff" || fail "sufficiency: $suff"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["stop"] in ("no-gain","exhausted","empty") and "zebra" in d["steps"][-1]["missing"] if d["steps"] else True, d' "$(b recall-check "$project_id" 'wage zebra quasar' --json)" || fail 'insufficient query stopped as sufficient'
grep -Fq 'pack=ok' <<<"$(b pack build "$project_id" --task 'CensusC extract wage' --sufficiency)" || fail 'sufficiency pack failed'

# ---- #4 standing constraints re-injected on schedule.
pack="$(b pack build "$project_id" --task 'wage study dataset' --turn 8 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'PROHIBITION: Never force-push main' "$pack" || fail 'constraint not re-injected at turn 8'
pack="$(b pack build "$project_id" --task 'wage study dataset' --turn 3 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
! grep -Fq 'Standing Constraints' "$pack" || fail 'constraint injected off schedule'
b label add "$project_id" okf/claims/method.md constraint:non-amplification --reason 'do not overstate' >/dev/null
grep -Fq 'non-amplification' <<<"$(b constraints "$project_id")" || fail 'label-declared constraint missing'

# ---- #10 working memory.
wm="$(b working add "$project_id" 'Finish the regional table' --session s1 | sed -n 's/.*item_id=\([^ ]*\).*/\1/p')"
b working add "$project_id" 'Bind run id 42 to the draft' --kind binding >/dev/null
fake_secret="pass""word = $(printf 'z%.0s' $(seq 1 20))"
b working add "$project_id" "$fake_secret" >/dev/null 2>&1 && fail 'secret working item accepted'
grep -Fq 'Finish the regional table' <<<"$(b working list "$project_id")" || fail 'working list'
pack="$(b pack build "$project_id" --task 'regional analysis' --session s1 | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq '## Working Memory' "$pack" || fail 'pack lacks working memory'
grep -Fq 'Open working items' <<<"$(b brief "$project_id")" || fail 'brief lacks working memory'
! grep -Fq 'Finish the regional table' <<<"$(b search "$project_id" 'regional table')" || fail 'working memory leaked into search'
b working done "$project_id" "$wm" >/dev/null
! grep -Fq 'Finish the regional table' <<<"$(b working list "$project_id")" || fail 'done working item still open'
grep -Fq 'Finish the regional table' <<<"$(b working list "$project_id" --all)" || fail 'working history lost'

# ---- #5 / #11 intentions: fire-once quiet, aftereffect, board, patches, observe.
once="$(b intention add "$project_id" --action 'Email the reviewer' --trigger keyword:reviewer --once | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
pack="$(b pack build "$project_id" --task 'reply to the reviewer' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'Email the reviewer' "$pack" || fail 'fire-once intention did not surface'
! grep -Fq "$once" <<<"$(b intention list "$project_id" --due --task 'reply to the reviewer')" || fail 'fire-once intention still due after firing'
grep -Fq "quiet	$once" <<<"$(b intention board "$project_id")" || fail 'board does not show quiet'
done_id="$(b intention add "$project_id" --action 'Archive raw extracts' --trigger keyword:archive | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
b intention done "$project_id" "$done_id" --reason archived >/dev/null
pack="$(b pack build "$project_id" --task 'archive the extracts' | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq 'do not repeat' "$pack" || fail 'completed cue aftereffect missing'
rev="$(b intention add "$project_id" --action 'Re-run the model' --trigger date:2099-12-01 --observe study.dataset | sed -n 's/.*intention_id=\([^ ]*\).*/\1/p')"
# Relative to today so the "revised, upcoming within 30 days" checks never expire.
soon="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc).date() + d.timedelta(days=10)).isoformat())')"
b intention revise "$project_id" "$rev" --reschedule "date:$soon" --reason 'moved up' >/dev/null
b intention revise "$project_id" "$rev" --override 'Re-run the model on CensusC' --reason 'dataset changed' >/dev/null
[ "$(tail -n +2 "$project_dir/intentions/$rev.patches.tsv" | wc -l | tr -d ' ')" = 2 ] || fail 'patches not appended'
grep -Fq 'date:2099-12-01' "$project_dir/intentions/$rev.patches.tsv" || fail 'old trigger not traceable'
grep -Fq "revised	$rev" <<<"$(b intention board "$project_id")" || fail 'board does not show revised'
obs="$(b intention observe "$project_id" --within-days 30)"
grep -Fq "$rev" <<<"$obs" || fail "observe missed upcoming intention: $obs"
grep -Fq 'okf/claims/dataset-v3.md' <<<"$obs" || fail "observe did not inspect hidden state: $obs"
b intention quiet "$project_id" "$rev" --until 2099-01-01 --reason snooze >/dev/null
grep -Fq "quiet	$rev" <<<"$(b intention board "$project_id")" || fail 'quiet patch ignored'

# ---- #6 folder summaries: derived, rebuildable, deterministic.
b browse build "$project_id" >/dev/null
summary="$project_dir/indexes/summaries/okf__claims.md"
[ -f "$summary" ] || fail 'claims summary missing'
grep -Fq '(superseded)' "$summary" || fail 'summary lacks lifecycle state'
first_hash="$(shasum -a 256 <"$summary")"
rm -rf "$project_dir/indexes/summaries"
b browse build "$project_id" >/dev/null
[ "$first_hash" = "$(shasum -a 256 <"$summary")" ] || fail 'summary not reproducible'
grep -Fq 'derived summary index' <<<"$(b browse show "$project_id" okf/claims)" || fail 'browse show'
b browse show "$project_id" ../.. >/dev/null 2>&1 && fail 'browse escaped the project'

# ---- #7 progressive state.
index="$(b state index "$project_id")"
grep -Fq $'study.dataset\tokf/claims/dataset-v3.md' <<<"$index" || fail "state index: $index"
! grep -Fq 'dataset-v1' <<<"$index" || fail 'superseded state in index'
printf '%s\n' "$index" >"$fixture/state.prev"
claim workers 'Worker count' 'There are 6 workers.' 2026-04-01T00:00:00Z 'brain_state_key: capacity.workers'
grep -Fq $'capacity.workers\tokf/claims/workers.md' <<<"$(b state index "$project_id" --since "$fixture/state.prev" --changes-only)" || fail 'incremental state update missed add'
grep -Fq 'CensusC 2024' <<<"$(b state open "$project_id" study.dataset)" || fail 'state open'
pack="$(b pack build "$project_id" --task 'capacity planning' --state-index | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
grep -Fq '## State Index' "$pack" || fail 'pack lacks state index'

# ---- #3 brief compaction.
for n in $(seq 1 30); do claim "fact-$n" "Fact number $n about the archive" "$(printf 'Long explanatory detail sentence %s. %.0s' "$n" $(seq 1 8))" 2026-01-01T00:00:00Z; done
compact="$(b brief "$project_id" --max-bytes 1500 --json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["compacted"] and d["bytes"]<=1500, d' "$compact" || fail 'brief did not compact'
plain="$(b brief "$project_id" --max-bytes 1500 --no-compact --json)"
python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); assert not b["compacted"] and a["omitted"]<b["omitted"], (a["omitted"], b["omitted"])' "$compact" "$plain" || fail 'compaction did not reduce omissions'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert not d["compacted"], d' "$(b brief "$project_id" --max-bytes 64000 --json)" || fail 'brief compacted below the cap'

printf 'lineage ideas self-check passed\n'
