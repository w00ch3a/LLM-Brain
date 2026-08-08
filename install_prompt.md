# Install LLM-Brain

You are installing LLM-Brain for this user from the official repository:

`https://github.com/w00ch3a/LLM-Brain`

Treat this as a local infrastructure change. Inspect the host before writing, use the latest stable GitHub Release unless the user selects another version, verify published checksums, and preserve any existing installation or vault.

## Ask before installation

Inspect the machine and identify the available agent hosts, current LLM-Brain installation, existing vaults and relevant workspace paths. Then ask the user to reply with `recommended` or override any of these choices:

1. **Agent hosts**
   - Which hosts should use LLM-Brain: Codex, Claude Code, Gemini CLI, Hermes Agent or another local agent?
   - Recommended: configure each detected host that the user confirms.

2. **Release source**
   - Latest stable GitHub Release, a specific version, or a local checkout?
   - Recommended: latest stable release from the official repository.

3. **Vault and project scope**
   - Create a new vault or use an existing one?
   - Ask for the vault path when the user does not accept the platform default.
   - Should each workspace resolve its own project, or should the host use one fixed project ID?
   - Recommended: platform-default vault path and automatic project resolution per workspace.

4. **Automatic behaviour**
   - Enable passive-to-the-user retrieval and authorised closeout capture?
   - Use selective reflection or the legacy reflect-all policy?
   - Recommended: automatic retrieval and capture with selective reflection. Do not require the user to invoke memory commands during normal work.

5. **Retrieval**
   - Choose lexical, configured vector or hybrid retrieval.
   - Ask whether recalled context must include supporting evidence and which token budget to use.
   - Ask for an existing local embedder only when the user chooses vector or hybrid retrieval. Do not install or download an embedding model without approval.
   - Recommended: hybrid with lexical fallback, evidence required and a 4,000-token recall budget.

6. **Privacy and visibility**
   - Ask which workspaces, file patterns, tool outputs or data classes capture must exclude.
   - Ask whether memory is shared or scoped by principal/audience.
   - Recommended: internal sensitivity, secret scanning, digest-only restricted tool results and no capture outside confirmed workspaces.

7. **Hermes options**, when Hermes is selected
   - Enable the `LLMBrainMemoryProvider` for automatic recall and durable capture?
   - Keep Hermes' built-in `compressor`, or opt into `LLMBrainContextEngine` for request-scoped memory selection?
   - Confirm the recall timeout and token budget.
   - Recommended: MemoryProvider enabled, built-in compressor retained, six-second timeout and 4,000-token budget.

8. **Experimental capabilities**
   - Prediction-error reflection: off, shadow or enabled?
   - Procedure replay: off or enabled?
   - Recommended: both off until the user has evaluation evidence.

9. **Existing-vault changes**
   - Ask whether the user wants read-only compatibility checks or a separately approved migration plan.
   - Recommended: run `migrate check` only. Never run `migrate apply`, `upgrade apply`, retraction, deletion or canonical promotion without explicit approval after showing the preflight.

Present the detected state and the proposed settings in one compact summary. Wait for the user's answer before installing.

## Installation rules

- Use argument arrays or quoted shell arguments. Do not execute downloaded text as a shell script.
- Download release archives and their `.sha256` files from the matching GitHub Release. Verify the checksum before extraction.
- Use `VERSION` as the package-version authority. Confirm every packaged CLI and host manifest reports the selected version.
- Install the pinned PyYAML runtime from `requirements-okf.lock`; do not substitute an unpinned dependency.
- Back up each host configuration or existing package before replacing it. Report the backup path.
- Keep durable memory as Markdown. Do not add a database, daemon, remote memory service or external graph store.
- Preserve source custody, episodes and review separately from canonical `okf/` memory.
- Never bypass locks. Wait for a live owner or recover ownership only when LLM-Brain proves the owner died.
- Keep provider calls, embeddings and index construction outside the short project commit lease.
- Do not copy credentials, private keys, tokens, personal records or unrelated private files into prompts, logs, test fixtures or public repositories.
- Do not commit, push, publish, migrate a live vault, activate experimental features or make paid model calls unless the user authorises that action.

## Host installation

### Codex, Claude Code and Gemini CLI

Prefer the host's native plugin or extension manager when the user already has a trusted marketplace or extension source configured. Use the published polyglot plugin archive for the selected release. Do not switch marketplace sources without approval.

If native plugin installation is unavailable, install the standalone package and add the repository's generic instructions only to the user-approved agent configuration.

Start a fresh host session after installation. Confirm automatic retrieval and closeout work without requiring the user to mention LLM-Brain.

### Hermes Agent

Use the source tree from the verified release tag and build the standalone Hermes package:

```bash
bash scripts/package-hermes-plugin.sh /path/to/staging/llm-brain
```

Install that directory under:

```text
$HERMES_HOME/plugins/llm-brain/
```

Write only these settings to `$HERMES_HOME/llm-brain.json`:

```json
{
  "vault_root": "/path/to/llm-brain-vault",
  "cli_path": "/path/to/llm-brain",
  "project_id": "",
  "strategy": "hybrid",
  "recall_budget_tokens": 4000,
  "timeout_seconds": 6
}
```

Activate and inspect the provider:

```bash
hermes memory setup llm-brain
hermes memory status
```

Keep `context.engine: compressor` unless the user selected the LLM-Brain ContextEngine. For the opt-in engine:

```bash
hermes plugins enable llm-brain --no-allow-tool-override
hermes config set context.engine llm-brain
```

The MemoryProvider must stop injecting recall while the ContextEngine owns it. Durable capture must continue.

### Other local agents

Use the host-neutral bridge instead of inventing another memory store:

```text
llm-brain bridge recall --source-root PATH --query-file FILE --principal ID --require-evidence
llm-brain bridge capture --source-root PATH --record FILE
```

JSON is transport only. Markdown in the vault remains authoritative.

## Verification

Run checks that match the installed host and report every skipped check:

1. Confirm the CLI and manifests report the selected version.
2. Run `detect`, `doctor`, and `lint` against the configured vault.
3. Confirm project resolution for one approved workspace.
4. Test provenance-labelled recall with a bounded budget.
5. Capture one clearly marked synthetic turn through the host integration.
6. Replay the same deterministic turn and prove it creates no second source or episode.
7. Confirm capture changed no canonical `okf/` file.
8. Confirm no pending or running work remains after the bounded drain.
9. Confirm timeout or malformed recall fails open.
10. For Hermes, confirm `memory status` reports `llm-brain` installed, available and active, and confirm the selected context engine matches the user's choice.

Do not use a real secret, private document or paid model call for the smoke test.

## Closeout

Report:

- selected version and verified checksums;
- installed hosts and package paths;
- vault and project IDs;
- effective retrieval, evidence, privacy and experimental settings;
- backup paths;
- tests passed, failed or skipped;
- whether a new session is required;
- any remaining migration, provider or host limitation.

Separate source state, installed state and runtime proof. Do not claim success from installation alone.
