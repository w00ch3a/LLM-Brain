# Install Memthena for me

Memthena was formerly called LLM-Brain; the command is still `llm-brain` (with `memthena` as an alias).

Give this entire file to the local agent or interface where you want Memthena installed.

---

You are installing Memthena for this user from the official repository:

`https://github.com/w00ch3a/LLM-Brain`

Your goal is to get useful, automatic memory working with the least effort from the user. Inspect first, recommend a safe setup, install it, test it and explain the result in plain language.

## Start here

Inspect the current agent host, operating system, existing Memthena installation and existing vaults without changing anything.

Then show one short confirmation in this format:

```text
Ready to install Memthena

It will:
- remember useful project context between sessions;
- show where recalled information came from;
- save memory as readable local Markdown;
- stay out of the way during normal work.

Choose one:
1. Install it for me (Recommended)
2. Show me options
3. Cancel
```

Do not present a technical questionnaire before this choice.

If the user chooses **Install it for me**, continue without asking about retrieval strategies, token budgets, reflection policies, project IDs, timeouts, migration modes or experimental flags.

Ask one additional question only when there is no safe default, an existing installation conflicts with the new one, or installation needs a separate download or external change not covered by installing Memthena. Put the recommended answer first and explain the choice in one sentence.

## Recommended settings

Apply this setup without making the user choose each item:

- Install the latest stable official release for the current agent host and verify its checksum.
- Use the normal local Markdown vault, with one memory project per workspace.
- Enable automatic recall, authorised end-of-task capture and selective reflection.
- Use an existing local vector provider when available; otherwise use built-in lexical search. Include evidence and use the standard 4,000-token budget.
- Enable privacy protections. Keep experiments and migrations off. For Hermes, enable the MemoryProvider and retain the built-in context compressor.
- Keep `LLM_BRAIN_COMMITMENT_POLICY=shadow`: record derived transition decisions without changing existing promotion behaviour. Current-state resolution and procedure capsules remain explicit opt-in workflows.
- Keep the default tiered review policy and lexical profile `v2`. If an existing vault has a review backlog, show `review sweep --all --dry-run` counts to the user; never run `--apply` without their explicit confirmation.
- Keep governed maintenance user-invocable: status is a bounded read-only check, reports are derived review candidates, and any schedule is host-native and separately verified.

Configure only the agent host receiving this prompt. Mention other detected hosts after installation as optional additions; do not modify them automatically.

## If the user chooses Show me options

Offer this short menu and ask which item they want to change:

1. **Apps** — choose which local agents use the memory.
2. **Memory location** — choose where the Markdown vault lives and whether projects share memory.
3. **Search** — keep fast built-in search or add an approved local vector model for broader matching.
4. **Privacy** — exclude particular workspaces, files or tool outputs.
5. **Advanced** — Hermes ContextEngine, experimental features, migration planning or other expert settings.

Show the recommended value beside each selected item. Ask only questions needed for the items the user chose, then return to the install confirmation.

## Installation rules

Must:

- Use the official release archive and matching `.sha256` file. Verify the checksum before extraction.
- Confirm the packaged CLI and host manifest match the selected `VERSION`.
- Install the PyYAML version pinned by `requirements-okf.lock`.
- Back up existing host configuration or packages before replacing them and report the backup location.
- Keep durable memory as Markdown. Do not add a database, daemon, remote memory service or external graph store.
- Do not install a scheduler, zvec engine or other new core dependency. Maintenance never deletes, retracts, promotes or rebuilds memory automatically.

Never:

- Never bypass locks. Wait for a live owner or recover ownership only when Memthena proves the owner died.
- Do not copy credentials, private keys, tokens, personal records or unrelated files into tests, logs or public repositories.
- Do not migrate a live vault, enable experimental capabilities, make paid model calls, commit, push or publish without separate approval.

Prefer the host's trusted plugin or extension manager when it is already configured. Do not change marketplace sources without approval.

For Hermes, install the standalone plugin under `$HERMES_HOME/plugins/llm-brain/`, run `hermes memory setup llm-brain`, and confirm `hermes memory status`. Keep `context.engine` set to `compressor` unless the user explicitly chose the Memthena ContextEngine.

For another local agent without a native plugin, use the host-neutral `bridge recall` and `bridge capture` commands rather than creating a second memory store.

## Test before claiming success

1. Confirm Memthena reports the selected version and passes `detect`, `doctor` and `lint` for the configured vault.
2. Resolve one approved workspace and recall a small provenance-labelled context block.
3. Capture one clearly marked synthetic turn, replay it and prove the replay creates no duplicate episode.
4. Confirm the test did not directly change canonical `okf/` memory and left no stuck work item.
5. Confirm unavailable or malformed recall fails open so the user's agent still works.
6. If maintenance is requested, confirm `maintenance status` is read-only and
   that any report is derived rather than canonical.

Do not use a real secret, private document or paid model call for testing.

## Finish with a simple result

Report only:

- **Installed:** version and current agent host.
- **Working:** automatic recall, automatic capture and tests that passed.
- **Stored at:** vault location and project ID.
- **Restart needed:** yes or no, with the exact action.
- **Not changed:** migrations, experimental features and any other detected agent hosts.

Keep technical logs available, but do not make the user read them unless a test failed.

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
