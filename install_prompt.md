# Install LLM-Brain for me

Give this entire file to the local agent or interface where you want LLM-Brain installed.

---

You are installing LLM-Brain for this user from the official repository:

`https://github.com/w00ch3a/LLM-Brain`

Your goal is to get useful, automatic memory working with the least effort from the user. Inspect first, recommend a safe setup, install it, test it and explain the result in plain language.

## Start here

Inspect the current agent host, operating system, existing LLM-Brain installation and existing vaults without changing anything.

Then show one short confirmation in this format:

```text
Ready to install LLM-Brain

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

Ask one additional question only when there is no safe default, an existing installation conflicts with the new one, or installation needs a separate download or external change not covered by installing LLM-Brain. Put the recommended answer first and explain the choice in one sentence.

## Recommended settings

Apply this setup without making the user choose each item:

- Install the latest stable official release for the current agent host and verify its checksum.
- Use the normal local Markdown vault, with one memory project per workspace.
- Enable automatic recall, authorised end-of-task capture and selective reflection.
- Use an existing local vector provider when available; otherwise use built-in lexical search. Include evidence and use the standard 4,000-token budget.
- Enable privacy protections. Keep experiments and migrations off. For Hermes, enable the MemoryProvider and retain the built-in context compressor.
- Keep `LLM_BRAIN_COMMITMENT_POLICY=shadow`: record derived transition decisions without changing existing promotion behaviour. Current-state resolution and procedure capsules remain explicit opt-in workflows.

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

Never:

- Never bypass locks. Wait for a live owner or recover ownership only when LLM-Brain proves the owner died.
- Do not copy credentials, private keys, tokens, personal records or unrelated files into tests, logs or public repositories.
- Do not migrate a live vault, enable experimental capabilities, make paid model calls, commit, push or publish without separate approval.

Prefer the host's trusted plugin or extension manager when it is already configured. Do not change marketplace sources without approval.

For Hermes, install the standalone plugin under `$HERMES_HOME/plugins/llm-brain/`, run `hermes memory setup llm-brain`, and confirm `hermes memory status`. Keep `context.engine` set to `compressor` unless the user explicitly chose the LLM-Brain ContextEngine.

For another local agent without a native plugin, use the host-neutral `bridge recall` and `bridge capture` commands rather than creating a second memory store.

## Test before claiming success

1. Confirm LLM-Brain reports the selected version and passes `detect`, `doctor` and `lint` for the configured vault.
2. Resolve one approved workspace and recall a small provenance-labelled context block.
3. Capture one clearly marked synthetic turn, replay it and prove the replay creates no duplicate episode.
4. Confirm the test did not directly change canonical `okf/` memory and left no stuck work item.
5. Confirm unavailable or malformed recall fails open so the user's agent still works.

Do not use a real secret, private document or paid model call for testing.

## Finish with a simple result

Report only:

- **Installed:** version and current agent host.
- **Working:** automatic recall, automatic capture and tests that passed.
- **Stored at:** vault location and project ID.
- **Restart needed:** yes or no, with the exact action.
- **Not changed:** migrations, experimental features and any other detected agent hosts.

Keep technical logs available, but do not make the user read them unless a test failed.
