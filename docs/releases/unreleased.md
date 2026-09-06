# Development / unreleased

This note records the current development scope only. It is not a release
announcement, installation proof, deployment statement or live-vault migration
record. `VERSION` remains the package-version authority.

## LLM-Brain upgrade work in progress

- Procedure capsules can declare explicit dependencies. `run prepare` records
  dependency references, content hashes and a dependency snapshot;
  `run validate` is read-only; `run start --capsule` rechecks the closure under
  the project lease. Changed, hidden, expired or unresolved dependencies make a
  capsule stale or blocked. Dependency-free legacy capsules retain their
  existing checks, while state-dependent legacy capsules require re-preparation.
- `search` and `pack build` accept explicit evidence intent. The intended
  lifecycle bundle is bounded, relationship-driven and visibility-filtered;
  JSON `evidence_bundles` preserve support, conflict, supersession, version,
  derivation, dependency and unresolved roles with state, excerpts and source
  hashes; warnings and `incomplete` remain warning-first. It is derived
  context, not canonical memory, and cannot increase authority.
- The repository-only `scripts/eval-lifecycle.py` provides a disposable,
  ground-truth-first evaluation harness with bounded JSON cases,
  allow-listed lifecycle events, twelve scenario families, 20-event and
  200-event checkpoints, six modes (`none`, `raw-source`, `factual`, `explicit`
  for `current_state`, `evidence` and `historical`), deterministic traces and
  optional answer-runner reporting. Checkpoints score
  stale-result leakage, provenance-root independence, repair isolation,
  capsule preparation/validation and poisoning resistance, as well as
  retrieval, unresolved-state, context/token, latency, degradation,
  operation/write-cost and repeat metrics. Distributed archives carry its
  documentation but not the evaluator or fixture files.

## Development acceptance caveats

The evaluator reports the declared ground-truth lifecycle and safety metrics
separately from optional answer-runner outcomes. An answer runner is a trusted
local executable with no OS sandbox requirement. A missing answer runner means
model-answer accuracy is unmeasured. The poisoning scenarios are bounded
regressions for authority laundering, restricted evidence, repair and
procedure-validation paths; they are not a claim of universal
prompt-injection resistance, factual truth or proof of a live deployment.

The existing schema-3 OKF format, factual retrieval default, current-state
opt-in behaviour, shadow commitment policy, Hermes provider/ContextEngine
contract and fail-open boundaries remain unchanged. No migration, external
action, automatic capsule execution or implicit lifecycle injection is implied.

See [the lifecycle evaluation guide](../evaluation.md) for the case schema,
runner contract, output files and acceptance boundary.
