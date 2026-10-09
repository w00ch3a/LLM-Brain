# LLM-Brain for Hermes Agent

This standalone plugin connects Hermes Agent to a local LLM-Brain vault. Hermes receives automatic project recall and durable turn capture while Markdown remains the source of truth.

The current release uses OKF v0.2 canonical records in storage schema 3. Hermes defaults remain unchanged: factual prefetch through the MemoryProvider and the native `compressor`; current-state and evidence retrieval are explicit caller choices.

## Components

### `LLMBrainMemoryProvider`

Hermes activates the provider through `hermes memory setup llm-brain` and `memory.provider: llm-brain`. It supports:

- local availability checks and profile-scoped configuration;
- pre-request recall through `llm-brain bridge recall`;
- non-blocking turn capture through `llm-brain bridge capture`;
- session switch/end and pre-compression capture, with optional checkpoint API v2;
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

### Optional governed maintenance

Maintenance is an explicit LLM-Brain CLI workflow, not a Hermes memory
provider feature. `maintenance preview` and `maintenance status` are
read-only; `maintenance run` writes only the bounded derived report under the
project's `maintenance/` directory. Reports cover freshness, retention
candidates, conflicts, work, receipts, indexes, provenance and retraction
residuals, while visibility filtering prevents restricted details from
appearing in output. They never delete, retract, promote, rebuild or inject
memory.

Host-native scheduling is optional. A `maintenance schedule declare` command
records an operator declaration for Hermes, Codex or cron; it does not install
or activate a scheduler. A recent successful report, not the declaration, is
the evidence that maintenance ran. Use the [maintenance skill](../../../skills/llm-brain-maintenance/SKILL.md)
for the manual workflow. This adds no change to the provider name, six-key
selector configuration, factual prefetch default, ContextEngine single
injector contract or fail-open behaviour.

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

These six keys are the selector configuration that `hermes memory setup` writes. An empty project ID resolves the registered Hermes workspace or creates a project for it. Other keys are ignored unless they are one of the opt-in settings below; setup rewrites keep any other keys already in the file (for example ones owned by a companion integration) and never write the opt-in settings as defaults.

### Opt-in settings

Add these to `llm-brain.json` by hand only when you need them. Absent keys keep the default behaviour.

| Key | Default | Purpose |
| --- | --- | --- |
| `laya_url` | `""` (off) | Local Laya typed-decisions endpoint used to filter recall. Blank disables the filter. |
| `laya_model` | `laya-typed-decisions` | Model name sent to that endpoint. |
| `laya_timeout_seconds` | `4` | Per-request timeout for the endpoint. |
| `laya_max_candidates` | `4` (maximum 4) | Recall results larger than this are passed through unfiltered. |
| `laya_min_relevance` | `0.55` | Minimum relevance probability for a result to be kept. |
| `laya_min_margin` | `0.1` | Minimum gap between the weakest kept and strongest dropped result; smaller gaps keep the original recall. |
| `context_engine_registration` | `always` | `always` registers the ContextEngine so it can be selected; `when-selected` registers it only while `context.engine` is `llm-brain`. |

**Laya recall filter.** When `laya_url` is set, each recall with between one and
`laya_max_candidates` results is sent to the endpoint as a bounded typed-decision request: the query (384 characters) and, per candidate, path, title, a 240-character excerpt and the recall score, with sensitive-looking text redacted first. The endpoint answers one `choice` triage question and one `noul` relevance probability per candidate. Results at or above `laya_min_relevance` are kept and the recall context is trimmed to them, preserving the recall header, supporting evidence and state warnings. The decision is recorded in an additive `local_laya` field.

The filter is fail-open. Recall is returned unfiltered, with `local_laya.status` set to `unavailable`, `ambiguous` or `candidate_limit`, when the endpoint times out, refuses the connection, redirects or returns a malformed or out-of-range answer, when no clear margin separates kept and dropped results, or when there are too many candidates. The endpoint must be `localhost` or a loopback, private or link-local IP literal (for example `http://localhost:8080/decide`); public addresses, other hostnames, embedded credentials, proxies and redirects are refused. The filter applies to automatic recall and to the `llm_brain_search` tool, and can add up to `laya_timeout_seconds` to a recall.

**Context-engine registration.** Hermes holds a single plugin context-engine slot and only uses a registered engine when `context.engine` names it. With the default `always`, LLM-Brain claims that slot whenever Hermes supports it, so a second context-engine plugin is rejected even though LLM-Brain's engine is not selected. Set `when-selected` to register only while `context.engine` is `llm-brain` (restart Hermes after changing `context.engine`). Recall and capture through the memory provider are unaffected either way.

**Bridge timeouts.** Each bridge call runs in its own process group. When `timeout_seconds` expires the whole group is stopped, so a timed-out recall or capture leaves no CLI processes behind holding or waiting for the vault lock on slow (for example NAS) storage. Bridge calls also set `LLM_BRAIN_LOCK_WAIT_SECONDS=2` unless the environment already sets it, so lock contention fails quickly and capture retries from the outbox.

## Capture lifecycle

Each deterministic request ID identifies one Markdown record:

```text
pending → running → committed
                 └→ failed → retry
```

Records live under `$HERMES_HOME/llm-brain/outbox/`. A short-lived standard-library worker claims a record, calls the CLI outside the project commit lease, then moves the record to `committed/`. A dead owner leaves recoverable Markdown. Replaying a committed request does not create another episode.

Hermes keeps working when recall times out or returns malformed JSON. Capture failures stay in the outbox with bounded attempts and error state.

By default pre-compression observation is best-effort and non-blocking. The outbox is durable work, but writing it is **not** a bridge completion receipt. On Hermes builds with checkpoint API v2, an operator may explicitly set `compression.checkpoint_required: true`. In that mode LLM-Brain synchronously captures Hermes' normalised direct user/assistant messages and returns success only after `bridge capture` reports a matching request ID, episode reference and source hash. Failure raises so Hermes keeps the uncompressed transcript for retry. Sensitive direct text is redacted before custody; that is a privacy boundary, not lossless transcript backup. Worker threads preserve the active Hermes profile context; older Hermes builds use a standard-library fallback.

This setting is not needed for ordinary use. Hermes documents that required checkpoints disable server-native compaction, micro-compaction and `codex_app_server` compaction paths; verify the host's desired compression behaviour before enabling it. No LLM-Brain selector configuration change is required.

## Host-neutral bridge

Other local agents can use the same JSON transport:

```text
llm-brain bridge recall --source-root PATH --query-file FILE --principal ID --require-evidence
llm-brain bridge capture --source-root PATH --record FILE
```

JSON is transport only. Source custody, episodes, reviews and canonical OKF remain Markdown in the vault.

`evidence_opened` means a visible custody source was read and its expected SHA-256 matched while rendering, not merely that a reference appeared in search. `evidence_incomplete` covers hidden, missing, changed, unverified and budget-omitted sources. These flags prove custody, not that an answer is semantically correct. New opt-in retrieval receipts retain their v1 JSONL shape, add identity version 2 and include rendered selection, principal, intent and as-of in idempotency; existing saved receipts are unchanged.

Current-state context keeps unresolved records in the bounded `context_markdown` warning section. Malformed JSON, unsupported fields and bridge timeouts remain fail-open. The MemoryProvider continues durable capture while the ContextEngine is selected, and remains suppressed as an injector in that mode. Native Hermes compression, token accounting, model switching, message ordering and tool-call/result pairing are untouched. Procedure capsules are prepared and started explicitly through the CLI; Hermes does not execute or inject them.

When a caller requests `intent: evidence`, the bridge includes bounded lifecycle `evidence_bundles` around selected records. Supporting, conflicting, historical, superseded and unresolved evidence remains labelled and source-bound; each entry carries its role/state, bounded excerpt and source hash, while `warnings` and `incomplete` report unresolved, hidden, truncated or budget-limited relationships. Hidden records are filtered before context or counts are rendered. The bundle is derived context, not canonical memory, and it cannot grant authority to external or derived text. Capsule dependency validation is likewise a CLI guard: Hermes does not prepare, validate, approve or execute capsules. These additions leave factual prefetch, the six configuration keys and the provider/ContextEngine single-injector contract unchanged.

## Runtime footprint

The adapter uses Python's standard library, Hermes' existing interfaces and the LLM-Brain CLI. It adds no daemon, database, network service, zvec engine or Python dependency; the opt-in Laya filter is a standard-library client for a local endpoint you run yourself. LLM-Brain's core remains OKF v0.2 and storage schema 3; any optional host-native scheduler is outside the core.

Retraction and receipts remain CLI-controlled: preview a canonical target with `retract ... --reason TEXT --preview`, then use the returned token with `retract ... --reason TEXT --confirm TOKEN`; `search ... --receipt` is opt-in and derived. The plugin never executes these actions automatically. LLM-Brain is provided under Apache License 2.0; applicable-law limits apply, and use, validation and deployment remain the user's responsibility without guarantees of correctness, security or fitness.
