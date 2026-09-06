---
name: llm-brain
description: Retrieve approved filesystem-first LLM-Brain context before non-trivial project work and capture an auditable outcome at closeout. Use advanced commands only for memory maintenance, migration, experiments, evaluation, or package work.
---

# LLM-Brain

For ordinary non-trivial project work:

1. Resolve the project from the configured registry, current Git root, origin, and physical path.
2. Retrieve relevant effective approved OKF records before work; current source, governing instructions, explicit human direction, and live proof outrank memory.
3. At closeout, capture an auditable episode and source-custody record when writes are authorised.
4. Keep `okf/` canonical; episodes, source custody, indexes, packs, adapters, and exports remain provenance or derived layers.

Use the local `llm-brain` CLI for `detect`, `search`, `pack build`, `stats`, `doctor`, and capture. Do not create projects, ingest, promote, migrate, overwrite adapters, commit, push, publish, or deploy without explicit authority.

Read the [full workflow](../../SKILL.md) only when the task requires memory maintenance, migration or upgrade, reflection/provider setup, promotion or commitment decisions, procedure capsules/runs, experiments/evaluation, adapter/export work, or package/release operations.

Hermes compatibility: preserve `memory.provider: llm-brain`, optional `context.engine: llm-brain`, the six configuration keys, native compressor defaults, fail-open current-state warnings, and the protected promotion policy. Set `LLM_BRAIN_PASSIVE=0` only when automatic retrieval and capture must be paused.

Current-state retrieval is opt-in: select `--intent current_state` explicitly; factual and historical retrieval keep their established behaviour. Unresolved state is warning material, not current truth. Candidates may request `persist`, `use-now`, `reverify`, `ask` or `quarantine`; `LLM_BRAIN_COMMITMENT_POLICY=shadow` is the default, so hash-bound decisions are derived records and the existing promotion policy remains authoritative. `enforce` applies the additional transition gate; `legacy` disables it.

## Advanced modes (read only when selected by the task)

When a procedure capsule is requested, include every explicit dependency that the task needs. `run prepare --depends-on REF` records the transitive locked dependency snapshot; `run validate PROJECT_ID CAPSULE_REF --json` is read-only, and `run start --capsule` must revalidate the same closure immediately before creating a run. A changed, hidden, expired or unresolved dependency requires re-preparation. Do not treat a capsule as authorisation for an external action.

Use `--intent evidence` only when the task needs the bounded lifecycle context around selected records. JSON `evidence_bundles` preserve supporting, conflicting, superseded, derived and unresolved roles, state, excerpts and source custody hashes; hidden evidence must not appear in explanations or counts, and warnings/incomplete mark unresolved or budget-limited relationships. External or derived text cannot gain authority through a summary or relationship.

The lifecycle evaluation harness is disposable and ground-truth-first. Run the repository-only `scripts/eval-lifecycle.py --cases CASES.json --output NEW_DIR --seed 0 --repeats 5`; it covers twelve scenario families at 20-event and 200-event checkpoints. It seeds facts, temporal validity, trust, visibility and as-of dates before applying updates, conflicts, poisoning, repair and capsule operations. Each checkpoint measures six modes—`none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`—plus stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance, together with candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. An optional answer runner adds model-answer outcomes; it is a trusted local executable with no OS sandbox requirement, and without one model-answer accuracy is unmeasured. Keep all evaluation output derived and outside canonical OKF memory. See `docs/evaluation.md`.
