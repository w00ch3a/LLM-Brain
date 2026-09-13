---
name: llm-brain
description: Retrieve approved filesystem-first LLM-Brain context before non-trivial project work and capture an auditable outcome at closeout. Use advanced commands only for memory maintenance, migration, experiments, evaluation, or package work.
---

# LLM-Brain

Canonical knowledge is OKF v0.2 with storage schema 3. Receipts are opt-in
(`search --receipt`); retraction is preview-then-confirm (`retract
--preview`, then `retract --confirm TOKEN`) and leaves historical custody
inspectable. Experimental and portability claims remain evaluation evidence
unless separately verified.

For ordinary non-trivial project work:

1. Resolve the project from the configured registry, current Git root, origin, and physical path.
2. Perform one bounded, read-only `maintenance status PROJECT_ID` check. Stay silent when the report is current; emit at most one concise stale-only reminder when it is stale. This check never runs maintenance or declares a schedule.
3. Retrieve relevant effective approved OKF records before work; current source, governing instructions, explicit human direction, and live proof outrank memory.
4. At closeout, capture an auditable episode and source-custody record when writes are authorised.
5. Keep `okf/` canonical; episodes, source custody, indexes, packs, adapters, exports and maintenance reports remain provenance or derived layers.

Use the local `llm-brain` CLI for `detect`, `search`, `pack build`, `stats`, `doctor`, and capture. Do not create projects, ingest, promote, migrate, overwrite adapters, commit, push, publish, or deploy without explicit authority.

Set `LLM_BRAIN_PASSIVE=0` to suppress the automatic status check as well as
automatic retrieval and capture. Use the [maintenance skill](../llm-brain-maintenance/SKILL.md)
only when a maintenance review, report or host-schedule declaration is
requested. A schedule declaration records operator intent; Hermes, Codex or
cron must be configured and verified separately.

Read the [full workflow](../../SKILL.md) only when the task requires memory maintenance, migration or upgrade, reflection/provider setup, promotion or commitment decisions, procedure capsules/runs, experiments/evaluation, adapter/export work, or package/release operations.

Hermes compatibility: preserve `memory.provider: llm-brain`, optional `context.engine: llm-brain`, the six configuration keys, native compressor defaults, fail-open current-state warnings, and the protected promotion policy. Set `LLM_BRAIN_PASSIVE=0` only when automatic retrieval and capture must be paused.

Current-state retrieval is opt-in: select `--intent current_state` explicitly; factual and historical retrieval keep their established behaviour. Unresolved state is warning material, not current truth. Candidates may request `persist`, `use-now`, `reverify`, `ask` or `quarantine`; `LLM_BRAIN_COMMITMENT_POLICY=shadow` is the default, so hash-bound decisions are derived records and the existing promotion policy remains authoritative. `enforce` applies the additional transition gate; `legacy` disables it.

Maintenance reports are derived, bounded and visibility-filtered. They expose
freshness, retention candidates, conflicts, dependencies, work, receipts,
indexes, provenance and retraction residuals without changing canonical OKF
memory. `maintenance preview` and `maintenance status` are read-only;
`maintenance run` writes only the latest report. No automatic deletion,
retraction, promotion, rebuild, daemon, database, zvec engine or core
dependency is introduced.

## Advanced modes (read only when selected by the task)

When a procedure capsule is requested, include every explicit dependency that the task needs. `run prepare --depends-on REF` records the transitive locked dependency snapshot; `run validate PROJECT_ID CAPSULE_REF --json` is read-only, and `run start --capsule` must revalidate the same closure immediately before creating a run. A changed, hidden, expired or unresolved dependency requires re-preparation. Do not treat a capsule as authorisation for an external action.

Use `--intent evidence` only when the task needs the bounded lifecycle context around selected records. JSON `evidence_bundles` preserve supporting, conflicting, superseded, derived and unresolved roles, state, excerpts and source custody hashes; hidden evidence must not appear in explanations or counts, and warnings/incomplete mark unresolved or budget-limited relationships. External or derived text cannot gain authority through a summary or relationship.

The lifecycle evaluation harness is disposable and ground-truth-first. Run the repository-only `scripts/eval-lifecycle.py --cases CASES.json --output NEW_DIR --seed 0 --repeats 5`; it covers twelve scenario families at 20-event and 200-event checkpoints. It seeds facts, temporal validity, trust, visibility and as-of dates before applying updates, conflicts, poisoning, repair and capsule operations. Each checkpoint measures six modes—`none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`—plus stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance, together with candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. An optional answer runner adds model-answer outcomes; it is a trusted local executable with no OS sandbox requirement, and without one model-answer accuracy is unmeasured. Keep all evaluation output derived and outside canonical OKF memory. See `docs/evaluation.md`.
