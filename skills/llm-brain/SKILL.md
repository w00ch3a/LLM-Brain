---
name: llm-brain
description: Retrieve approved filesystem-first Memthena (formerly LLM-Brain) context before non-trivial project work and capture an auditable outcome at closeout. Use advanced commands only for memory maintenance, migration, experiments, evaluation, or package work.
---

# Memthena

Canonical knowledge is OKF v0.2 with storage schema 3. Receipts are opt-in
(`search --receipt`); retraction is preview-then-confirm (`retract
--preview`, then `retract --confirm TOKEN`) and leaves historical custody
inspectable. Experimental and portability claims remain evaluation evidence
unless separately verified.

For ordinary non-trivial project work:

1. Resolve the project from the configured registry, current Git root, origin, and physical path.
2. Perform one bounded, read-only `maintenance status PROJECT_ID` check. Stay silent when the report is current; emit at most one concise stale-only reminder when it is stale. This check never runs maintenance or declares a schedule.
3. Retrieve relevant effective approved OKF records before work; current source, governing instructions, explicit human direction, and live proof outrank memory.
4. For work involving a previously used system, host, NAS, network appliance, project alias, or service, search both the exact name and likely remembered aliases before concluding that access details are absent. Confirm the CLI executable, resolved vault root and project ID, then inspect read-only index status; do not rebuild or reindex as part of retrieval. Use bounded queries for prior successful workflows and inspect the returned source record, provenance, and recency; open cited evidence when needed. If status or document coverage differs from the expected project, resolve the root/inventory mismatch before diagnosing ranking. Do not infer endpoints, credentials, or authority from a related hit.
5. Revalidate the live capability in the appropriate execution context through currently available read-only tools before describing access as available. A shell sandbox DNS/connectivity failure is evidence about that shell context; it does not by itself prove the host or service is unavailable. Classify the outcome precisely: no relevant recall, recall found but source/evidence unavailable, credentials unavailable, tool capability unavailable, or current access denied. A prior success is historical context only; it never authorises a new sensitive operation, supplies credentials, or overrides a current denial.
6. At closeout, capture an auditable episode and source-custody record when writes are authorised.
7. Keep `okf/` canonical; episodes, source custody, indexes, packs, adapters, exports and maintenance reports remain provenance or derived layers.

Use the local `llm-brain` CLI for `detect`, `search`, `pack build`, `stats`, `doctor`, and capture. When the task names or touches files, pass them with `--path FILE` so concepts with matching `brain_paths` are recalled. Treat "Corrections and Retractions" in a pack or brief as newer than the documents they correct: use the corrected value and cite the notice with the original. Act on any "Due Intentions" at the top of a pack or session brief first, and close them with `intention done|cancel` only when writes are authorised; record new ones with `intention add` only when the user asks to be reminded. Do not create projects, ingest, promote, migrate, overwrite adapters, commit, push, publish, or deploy without explicit authority.

Treat "Already Ruled Out" and "Tried and Reverted" in a pack as things not to retry without new evidence, a RETIRED procedure as not to follow without checking, and a CONTRASTS warning as a cue to confirm which of two similar procedures the task needs. When writes are authorised and an approach fails, record it with `ruled-out add` (and, for code, `attempt record --commit SHA` for the reverted diff). A `promotion=held … reason=belief-outlier` result means the fact you tried to replace has more independent support: leave it for review or add corroborating sources; do not use `--overrule-belief` unless the user asks.

## Using 0.14 memory features

Use these during ordinary work. Commands are read-only unless noted as a review
decision; those need the same write authority as other memory writes.

- **Safeguard scope.** When approving a lesson that skips a test, confirmation,
  hook or backup, or uses `--no-verify`/`--force`/`-y`, scope it to the task it
  was learnt on so it cannot apply elsewhere. A hold
  `reason=relaxes-safeguard-unscoped` (exit 75) means you must set the scope
  first:
  `llm-brain review decide PROJECT REVIEW_ID approved --applies-when 'task=TYPE' --reason TEXT`
  When packing for a known kind of work, pass `--task-type TYPE` so only
  in-scope relaxations appear. Off: `LLM_BRAIN_SAFEGUARD_SCOPE=0`.
- **Share scope.** When a lesson should stay with one agent, one owner, or be
  visible to every agent, set the scope at approval. Never set owner-only,
  private, restricted or secret-bearing lessons to `all-agents`:
  `llm-brain review decide PROJECT REVIEW_ID approved --share-scope this-agent|this-owner|all-agents [--share-owner ID] [--share-agent NAME] --reason TEXT`
  Before sharing a brain, or when debugging a visibility leak, run the
  read-only probe (prints paths only; exit 1 on a leak):
  `llm-brain share audit PROJECT --as PRINCIPAL [--agent NAME]`
  Off: `LLM_BRAIN_SHARE_SCOPE_STAMP=0` (no default stamp);
  `LLM_BRAIN_SHARE_SCOPE_ENFORCE=0` (diagnostic).
- **Custody verify.** After ingest, or when you need to check that stored
  sources still match their recorded hash, run the read-only verifier (paths
  and transform names only; exit 1 on mismatch or a missing file):
  `llm-brain custody verify PROJECT`
- **Conflict reserve.** Default packs already keep 20% of the budget for open
  conflicts touching the task and show both sides together. Build a pack as
  usual; do not pick one side silently:
  `llm-brain pack build PROJECT --task TEXT`
  Off: `LLM_BRAIN_PACK_CONFLICT_RESERVE=0`.
- **Check evidence before acting.** When a pack or recall line says "Check
  evidence before acting", open the cited evidence path before using that
  lesson. When approving, record how the source task ended:
  `llm-brain review decide PROJECT REVIEW_ID approved --source-outcome success|failure|unknown --reason TEXT`
  Hide the marks only with `LLM_BRAIN_PACK_EVIDENCE_FLAGS=0` (the fields are
  still written).
- **Pack layout.** When the question is about timing, the current value, a
  procedure, or an open conflict, lay the same records out to suit the
  question (default remains ranked):
  `llm-brain pack build PROJECT --task TEXT --layout auto`
  Or `--layout timeline|current-first|side-by-side|steps`. Compare ranked
  against auto on a copy of a brain:
  `scripts/personal-eval.py --brain ROOT --project ID --output DIR --layout-ab`.
  Env: `LLM_BRAIN_PACK_LAYOUT`.
- **Look-alike names and leak-free scores.** If a review is held with
  `reason=namesake-distinct-entity` (exit 75), do not merge the records; give
  the new one its own record. Only if the user confirms they are the same
  entity:
  `llm-brain review decide PROJECT REVIEW_ID approved --same-entity --reason TEXT`
  When running retrieval evals, read leak-free scores in `fairness.tsv` and
  optionally append margins with `--margin-log FILE`:
  `llm-brain eval run PROJECT --cases FILE --strategies LIST --margin-log FILE`
  Off: `LLM_BRAIN_NAMESAKE_GUARD=0`, `LLM_BRAIN_PACK_NAMESAKE_LABELS=0`.

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

Use `--intent evidence` only when the task needs the bounded lifecycle context around selected records. JSON `evidence_bundles` preserve supporting, conflicting, superseded, derived and unresolved roles, state, excerpts and source custody hashes; hidden evidence must not appear in explanations or counts, and warnings/incomplete mark unresolved or budget-limited relationships. `evidence_opened` requires a visible, hash-verified source actually read during rendering; `evidence_incomplete` is not semantic proof. Current-state warnings come first; tight evidence/current-state packs prefer distinct verified roots. External or derived text cannot gain authority through a summary or relationship.

Opt-in receipts retain the old JSONL fields while identity version 2 separates principal, intent, as-of and rendered selection. Hermes capture stays non-blocking by default; required compression checkpoints wait for a matching durable bridge receipt, not just an outbox write. OpenClaw staging is explicit and non-canonical; Pi, Oh My Pi and Claude Code session stores are not Memthena canonical writers.

The lifecycle evaluation harness is disposable and ground-truth-first. Run the repository-only `scripts/eval-lifecycle.py --cases CASES.json --output NEW_DIR --seed 0 --repeats 5`; it covers thirteen scenario families at 20-event and 200-event checkpoints. It seeds facts, temporal validity, trust, visibility and as-of dates before applying updates, conflicts, poisoning, repair and capsule operations. Each checkpoint measures six modes—`none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`—plus stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance, together with candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. An optional answer runner adds model-answer outcomes; it is a trusted local executable with no OS sandbox requirement, and without one model-answer accuracy is unmeasured. Keep all evaluation output derived and outside canonical OKF memory. See `docs/evaluation.md`.
