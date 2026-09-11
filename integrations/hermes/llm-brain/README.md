# LLM-Brain for Hermes Agent

This standalone plugin connects Hermes Agent to a local LLM-Brain vault. Hermes receives automatic project recall and durable turn capture while Markdown remains the source of truth.

The current local candidate uses OKF v0.2 canonical records in storage schema 3. Hermes defaults remain unchanged: factual prefetch through the MemoryProvider and the native `compressor`; current-state and evidence retrieval are explicit caller choices.

## Components

### `LLMBrainMemoryProvider`

Hermes activates the provider through `hermes memory setup llm-brain` and `memory.provider: llm-brain`. It supports:

- local availability checks and profile-scoped configuration;
- pre-request recall through `llm-brain bridge recall`;
- non-blocking turn capture through `llm-brain bridge capture`;
- session switch/end and pre-compression capture;
- built-in memory-write and parent-delegation capture;
- an atomic, recoverable Markdown outbox;
- bounded shutdown draining;
- the `llm_brain_search` agent tool.

Primary-agent turns store full user and assistant text plus session, principal, platform and delegation lineage. Tool evidence stores names, call IDs, outcomes and result hashes. Each safe excerpt is capped at 8 KiB, with a 64 KiB total cap per turn. Sensitive results keep the hash and call lineage without content-derived paths, status text or excerpts.

The provider captures evidence into `sources/`, `episodes/` and `review/`. It cannot write `okf/` directly.

The existing selector contract is unchanged: the provider name is `llm-brain`, the six configuration keys are `vault_root`, `cli_path`, `project_id`, `strategy`, `recall_budget_tokens` and `timeout_seconds`, and saved configuration is loaded without rewriting. Automatic provider prefetch and ContextEngine recall always use factual intent in this release. The `llm_brain_search` tool accepts an optional `intent` of `factual`, `current_state`, `historical`, `procedure`, `evidence` or `exploratory`; `current_state` and lifecycle evidence bundles are never selected implicitly. Explicit evidence intent adds structured `evidence_bundles` entries with role, state, excerpt, source hash, warnings and incomplete markers. New state, relation and independent-source fields in bridge JSON are additive and older Hermes installations may ignore them.

### `LLMBrainContextEngine`

The optional context engine subclasses Hermes' `ContextCompressor`. It keeps native compression, model updates and token counters, then inserts one bounded memory block into the current request. It preserves system/developer messages, tool-call/result pairing and the latest user request.

Select it with:

```bash
hermes plugins enable llm-brain --no-allow-tool-override
hermes config set context.engine llm-brain
```

The provider stops injecting recall while this engine owns context selection. Capture continues. Set `context.engine` back to `compressor` to restore Hermes' built-in context selection.

## Install

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
bash scripts/package-hermes-plugin.sh dist/hermes/llm-brain
mkdir -p "$HERMES_HOME/plugins"
cp -R dist/hermes/llm-brain "$HERMES_HOME/plugins/"
hermes memory setup llm-brain
hermes memory status
```

Create `$HERMES_HOME/llm-brain.json` when the vault or CLI is outside the normal search paths:

```json
{
  "vault_root": "/path/to/llm-brain-vault",
  "cli_path": "/path/to/LLM-Brain/bin/llm-brain",
  "project_id": "",
  "strategy": "hybrid",
  "recall_budget_tokens": 4000,
  "timeout_seconds": 6
}
```

The plugin accepts only those six keys. An empty project ID resolves the registered Hermes workspace or creates a project for it.

## Capture lifecycle

Each deterministic request ID identifies one Markdown record:

```text
pending → running → committed
                 └→ failed → retry
```

Records live under `$HERMES_HOME/llm-brain/outbox/`. A short-lived standard-library worker claims a record, calls the CLI outside the project commit lease, then moves the record to `committed/`. A dead owner leaves recoverable Markdown. Replaying a committed request does not create another episode.

Hermes keeps working when recall times out or returns malformed JSON. Capture failures stay in the outbox with bounded attempts and error state.

## Host-neutral bridge

Other local agents can use the same JSON transport:

```text
llm-brain bridge recall --source-root PATH --query-file FILE --principal ID --require-evidence
llm-brain bridge capture --source-root PATH --record FILE
```

JSON is transport only. Source custody, episodes, reviews and canonical OKF remain Markdown in the vault.

Current-state context keeps unresolved records in the bounded `context_markdown` warning section. Malformed JSON, unsupported fields and bridge timeouts remain fail-open. The MemoryProvider continues durable capture while the ContextEngine is selected, and remains suppressed as an injector in that mode. Native Hermes compression, token accounting, model switching, message ordering and tool-call/result pairing are untouched. Procedure capsules are prepared and started explicitly through the CLI; Hermes does not execute or inject them.

When a caller requests `intent: evidence`, the bridge includes bounded lifecycle `evidence_bundles` around selected records. Supporting, conflicting, historical, superseded and unresolved evidence remains labelled and source-bound; each entry carries its role/state, bounded excerpt and source hash, while `warnings` and `incomplete` report unresolved, hidden, truncated or budget-limited relationships. Hidden records are filtered before context or counts are rendered. The bundle is derived context, not canonical memory, and it cannot grant authority to external or derived text. Capsule dependency validation is likewise a CLI guard: Hermes does not prepare, validate, approve or execute capsules. These additions leave factual prefetch, the six configuration keys and the provider/ContextEngine single-injector contract unchanged.

## Runtime footprint

The adapter uses Python's standard library, Hermes' existing interfaces and the LLM-Brain CLI. It adds no daemon, database, network service or Python dependency.

Retraction and receipts remain CLI-controlled: preview a canonical target with `retract ... --reason TEXT --preview`, then use the returned token with `retract ... --reason TEXT --confirm TOKEN`; `search ... --receipt` is opt-in and derived. The plugin never executes these actions automatically. LLM-Brain is provided under Apache License 2.0; applicable-law limits apply, and use, validation and deployment remain the user's responsibility without guarantees of correctness, security or fitness.
