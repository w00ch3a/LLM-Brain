# Lifecycle evaluation (repository-only harness)

This document describes the ground-truth lifecycle harness in the repository
source checkout. It is deliberately repository-only: the evaluator and fixture
cases are not shipped in the plugin or standalone archives, while this guide is
included as reference documentation. Every scenario runs in a disposable vault
that is removed after scoring. The output directory must be new, and evaluation
output is derived data rather than canonical memory.

## Run the harness

From the repository root:

```bash
python3 scripts/eval-lifecycle.py \
  --cases tests/fixtures/lifecycle/cases.v1.json \
  --output /tmp/llm-brain-lifecycle-run-NEW \
  --seed 0 \
  --repeats 5
```

`--cases` and `--output` are required. The output path must not already exist.
`--seed` is a non-negative run-identity field (default `0`) and `--repeats`
is bounded to `1..50` (default `5`). An optional executable answer runner is
provided with `--answer-runner PATH`; without it, model-answer accuracy is
unmeasured. The runner is a trusted local executable; no OS sandbox is required.
It receives only a bounded question/evidence request and a result path; expected
paths and fixture truth stay host-side.

The checked-in case contract is JSON:

```json
{
  "format": "llm-brain.lifecycle-evaluation",
  "version": 1,
  "horizons": [20, 200],
  "scenario_families": [
    {
      "id": "state-replacement",
      "description": "A bounded replacement and retrieval history",
      "ground_truth": {
        "records": [
          {"id": "procedure-1", "kind": "procedure", "title": "Example", "text": "..."}
        ],
        "queries": [
          {"id": "q1", "text": "Example", "expected_paths": ["procedure-1"]}
        ]
      },
      "events": []
    }
  ]
}
```

Records are materialised as canonical fixture state before source or
conversation events. Events are data-only and limited to capture, review,
replacement, retraction, retrieval, preparation and validation; command and
shell fields are rejected. Queries may declare expected paths/states, forbidden
or visibility-forbidden paths, an as-of timestamp, a principal and the
checkpoint assertions required for that query.

## Scenarios and checkpoints

The harness covers twelve scenario families at short (20-event) and long
(200-event) checkpoints. Each family/horizon receives its own temporary vault.
The event timeline is replayed in order, with retrieval and procedure
checkpoints evaluated at their declared point so later updates, retractions or
poisoned text cannot leak backwards into an earlier result.

Each checkpoint compares six bounded modes:

- `none`: no memory candidates;
- `raw-source`: bounded raw-source matching;
- `factual`: lexical retrieval with `--intent factual`; and
- `explicit`: lexical retrieval with `--intent current_state`;
- `evidence`: lexical retrieval with `--intent evidence` and bounded lifecycle bundles; and
- `historical`: lexical retrieval with `--intent historical`.

`explicit` is the only state-resolving mode. Lifecycle evidence bundles are
requested only by `evidence`; they are not implicit in factual, current-state
or historical retrieval.

## Measured results

Ground-truth scoring covers the retrieval and safety properties the scenarios
declare, including:

- expected-path/state hits and ranks, including negative and forbidden-path
  cases;
- stale-result and future-event leakage, retraction handling and as-of state;
- provenance-root correctness, independent-root counts and correlated-record
  handling;
- visibility filtering and unresolved/incomplete state warnings;
- repair isolation, including preservation of unrelated source custody;
- procedure capsule preparation and read-only validation, including dependency
  and stale-state checks; and
- bounded poisoning regressions for authority laundering, restricted evidence,
  quarantine/retraction and attempted procedure validation.

Trace and summary metrics also include unresolved results, context bytes and
token estimates, latency, retrieval degradation/fallback, operation and memory
write cost, and repeat reliability. These are deterministic ground-truth or
host-measured results, not claims about a model's answer quality.

An answer runner can add separately labelled outcomes and token counts. Runner
results never replace fixture scoring, and no answer runner means model-answer
accuracy is reported as unmeasured rather than inferred from retrieval hits.

Each run identity and trace also records the provider, provider version and
commit, model and embedding dimension, repository commit, build status,
warm/cold state, availability, degraded path, declared evaluation budget and
the bounded configuration. These fields identify the build and execution
conditions; they do not turn an unavailable or degraded path into a model
winner.

## Output and identity

Successful runs write:

- `run.json`, binding the case, CLI, evaluator, answer-runner, seed and repeat
  hashes to a run identity;
- `trace.jsonl`, the complete machine-readable event/checkpoint trace;
- `trace.tsv`, a tabular trace;
- `summary.json`, per-mode retrieval, lifecycle, cost and repeat metrics; and
- `report.md`, a short human-readable report.

When an answer runner is configured, `answer-requests/` contains one bounded
request/result pair per answer checkpoint. Requests contain the question and
selected evidence only; expected paths and fixture truth are not included.

All records, traces, reports and runner artefacts are disposable derived data.
Do not import them into canonical OKF memory, promote their text, or treat an
answer runner as an authority source. The harness exercises only local CLI
operations and does not execute external actions.
