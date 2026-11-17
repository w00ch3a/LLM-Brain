# Memthena automatic-use contract

Unless `LLM_BRAIN_PASSIVE=0`, automatically resolve the current project in the configured Memthena vault, perform one bounded read-only `maintenance status PROJECT_ID` check, and retrieve relevant effective OKF memory before every non-trivial project task. Stay silent when the maintenance report is current; emit at most one concise stale-only reminder when it is stale. At authorised closeout, capture the task and route durable candidates through review. Memthena is active infrastructure; only the user experience is passive. Current source, governing instructions, explicit user direction and live proof outrank memory. Maintenance reports and schedule declarations are derived; never run, schedule, delete, retract, promote or inject them automatically. Never silently auto-promote protected material, and never require the user to name Memthena. Set `LLM_BRAIN_PASSIVE=0` to suppress the automatic check, retrieval and capture. Keep OKF v0.2, storage schema 3 and the Hermes provider/context contracts unchanged.

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
