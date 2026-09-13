# Development / unreleased

This note records the current development scope after the v0.7.1
release. It is not a release
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
- Governed maintenance adds bounded `preview`, `status` and explicit `run`
  views for freshness, retention candidates, conflicts/dependencies, work,
  receipts, indexes, provenance and retraction residuals. Reports are
  visibility-filtered derived Markdown under `maintenance/`; they never
  delete, retract, promote or rebuild canonical memory. Host-native schedule
  declarations are operator records only and do not install a scheduler.

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
contract and fail-open boundaries remain unchanged. Maintenance status is one
bounded read-only check after project resolution, with at most one stale-only
reminder; `LLM_BRAIN_PASSIVE=0` suppresses it. No migration, external action,
automatic capsule execution, implicit lifecycle injection, zvec engine,
database or daemon is implied.

Receipts are opt-in derived records (`search --receipt`); forgetting remains a
preview/confirm operation (`retract --preview`, then `retract --confirm TOKEN`)
that records a tombstone without deleting custody. Portability, repair and
research scenarios in the lifecycle evaluator are evaluation evidence only;
without an answer runner, model-answer accuracy is unmeasured. Future changes
belong here until a dated release note is created.

See [the lifecycle evaluation guide](../evaluation.md) for the case schema,
runner contract, output files and acceptance boundary.
