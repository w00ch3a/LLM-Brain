# LLM-Brain

<p align="center">
  <img src="docs/assets/llm-brain-logo.png" alt="LLM-Brain" width="640">
</p>

[![Release](https://img.shields.io/github/v/release/w00ch3a/LLM-Brain)](https://github.com/w00ch3a/LLM-Brain/releases)
[![License](https://img.shields.io/github/license/w00ch3a/LLM-Brain)](LICENSE)
[![Storage](https://img.shields.io/badge/storage-Markdown-4B5563)](references/architecture.md)

**Durable, inspectable memory for AI agents.**

LLM-Brain gives Codex, Claude Code, Gemini CLI, Hermes Agent and custom agents a shared project memory. It stores knowledge as Markdown, tracks the evidence behind each claim, and retrieves the right context before an agent starts work.

The infrastructure stays active. You do not have to invoke it, clear lock files or manage a memory queue during normal work.

## Easiest install

1. Open [`install_prompt.md`](install_prompt.md).
2. Give the whole file to Codex, Claude Code, Gemini CLI, Hermes or another capable local agent.
3. Choose **Install it for me**.

The agent detects the current host, proposes safe defaults, installs a checksum-verified release and tests it. Choose **Show me options** only when you want to change the memory location, search, privacy or advanced settings.

```text
authoritative files
       │
       ▼
 sources/ ──► episodes/ ──► review/ ──► okf/
                    │                     │
                    └──── provenance ─────┤
                                          ▼
                            lexical · vector · graph
                                          │
                                          ▼
                              state-safe context packs
                                          │
                                          ▼
                                        agent
```

Canonical knowledge follows [Google Open Knowledge Format v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/3fcbb9f828c2f23d109c855ee403c3a4c81f3a96/okf/SPEC.md). Raw evidence, episodes, review decisions and audit records remain beside it, so an agent can cite where a memory came from and revise it without erasing history.

## Why agents use it

| Need | LLM-Brain behaviour |
|---|---|
| Context survives sessions | Project memory lives on disk instead of inside one chat window. |
| Humans stay out of the plumbing | Agents retrieve context and capture authorised closeouts through host integrations. |
| Claims remain accountable | SHA-256 source custody, lineage, trust, temporal state and review decisions travel with memory. |
| Parallel agents keep working | Writers wait or recover proven-dead ownership; slow providers and embedders run outside the commit lease. |
| Old knowledge stays understandable | Supersession, retraction, conflicts and as-of retrieval preserve history. |
| Retrieval stays honest | Exact identifiers remain lexical, unavailable vector state reports degradation, and context packs expose their evidence. |

## Install

LLM-Brain uses Bash, Python and pinned PyYAML. It does not require a database or daemon.

```bash
git clone https://github.com/w00ch3a/LLM-Brain.git
cd LLM-Brain
python3 -m venv .venv
.venv/bin/pip install --require-hashes --no-binary PyYAML -r requirements-okf.lock
export LLM_BRAIN_OKF_PYTHON="$PWD/.venv/bin/python"
./bin/llm-brain --version
```

Packaged installations create the same pinned runtime during `upgrade apply`.

The polyglot plugin archive supports:

- Codex through `.codex-plugin/plugin.json`;
- Claude Code through `.claude-plugin/` and `SessionStart` hooks;
- Gemini CLI through `gemini-extension.json` and `GEMINI.md`;
- generic agents through `adapters/generic.md`.

Set `LLM_BRAIN_PASSIVE=0` when a session must opt out of automatic retrieval and closeout.

## First run

Global options go before the command:

```bash
brain="./bin/llm-brain --root /path/to/llm-brain-vault"

$brain project ensure /path/to/repository
$brain search PROJECT_ID "current task" --require-evidence
$brain pack build PROJECT_ID --task "current task" --budget-tokens 4000
```

The project layout stays readable without LLM-Brain:

```text
projects/PROJECT_ID/
├── sources/          # content-addressed evidence
├── episodes/         # captured events and provenance
├── review/           # candidates, conflicts and reconsolidation proposals
├── okf/              # canonical Markdown knowledge
├── requests/         # recoverable background work
├── indexes/          # rebuildable lexical, graph and vector data
├── context-packs/    # bounded retrieval output
├── runs/             # procedure working state and outcomes
└── audit.v2.tsv      # hash-chained lifecycle events
```

## Hermes Agent memory plugin

The standalone plugin in [`integrations/hermes/llm-brain/`](integrations/hermes/llm-brain/) makes LLM-Brain a native Hermes memory provider. Hermes can retrieve project context before a request and capture each completed turn without a model-specific adapter.

### MemoryProvider

`LLMBrainMemoryProvider` supplies the complete Hermes memory lifecycle:

- local availability and profile-scoped setup;
- automatic prefetch through `bridge recall`;
- non-blocking turn capture through an atomic Markdown outbox;
- session, compression, memory-write and parent-delegation capture;
- bounded shutdown draining and dead-owner recovery;
- the `llm_brain_search` agent tool;
- fail-open recall when the CLI times out or returns malformed data.

Each primary-agent turn records the user and assistant text, session lineage, tool names, call IDs and outcomes. Tool results keep a full SHA-256 hash with bounded UTF-8 excerpts. Sensitive tool output becomes digest-only evidence. The plugin sends records through source custody, episodes and review; it never writes canonical `okf/` files.

```text
completed Hermes turn
        │
        ▼
$HERMES_HOME/llm-brain/outbox/REQUEST_ID.md
        │  atomic claim + bounded worker
        ▼
llm-brain bridge capture
        │
        ├──► sources/
        ├──► episodes/
        └──► review/
```

### Install and activate memory

Build the package from this repository and place it in the active Hermes profile:

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
bash scripts/package-hermes-plugin.sh dist/hermes/llm-brain
mkdir -p "$HERMES_HOME/plugins"
cp -R dist/hermes/llm-brain "$HERMES_HOME/plugins/"
hermes memory setup llm-brain
hermes memory status
```

Store the six supported settings in `$HERMES_HOME/llm-brain.json`:

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

An empty `project_id` lets the plugin resolve the registered Hermes workspace or create a project for it. Multiple Hermes sessions can capture into the same project. They share short commit leases while provider calls and retrieval work continue outside those leases.

### Optional ContextEngine

`LLMBrainContextEngine` subclasses Hermes' native `ContextCompressor`. It preserves Hermes compression, token accounting and model-switch behaviour, then inserts one request-scoped provenance block. Selection does not modify stored conversation history.

MemoryProvider recall is the safe setup default. Enable the context engine when LLM-Brain should own request context selection:

```bash
hermes plugins enable llm-brain --no-allow-tool-override
hermes config set context.engine llm-brain
```

The MemoryProvider stops injecting recall while the ContextEngine owns it. Durable capture continues through the provider. Restore Hermes' built-in engine with:

```bash
hermes config set context.engine compressor
```

The plugin uses no network service, database, daemon or extra Python package. See the [Hermes integration guide](integrations/hermes/llm-brain/README.md) for lifecycle and recovery details.

## Host-neutral bridge

Other local agents can use the same transport without importing Hermes code:

```bash
./bin/llm-brain --root /path/to/llm-brain-vault bridge recall \
  --source-root /path/to/repository \
  --query-file query.txt \
  --principal agent-id \
  --budget-tokens 4000 \
  --require-evidence

./bin/llm-brain --root /path/to/llm-brain-vault bridge capture \
  --source-root /path/to/repository \
  --record turn.md
```

Each bridge command writes one JSON object to stdout. JSON carries transport data; Markdown remains authoritative. Capture returns a deterministic request ID, project-relative episode and review references, a source hash and the idempotency result. Recall returns the requested and actual strategy, fallback state, evidence references and bounded Markdown context.

## Retrieval and memory control

LLM-Brain supports:

- lexical, configured vector, hybrid and graph-expanded retrieval;
- conflict-aware Hermes evidence retrieval that ranks user content separately from assistant suggestions, preserves competing dates, and exposes resolution mode and provenance in bridge JSON;
- exact identifier, factual, current-state, historical, procedure, evidence and exploratory intents;
- current and as-of temporal views with unknown-validity handling;
- opt-in state resolution that follows validity, retraction, visibility, supersession/version chains and dependencies. Conflicts are reported as warnings, never selected as current truth;
- independent-source accounting over selected evidence, so repeated records derived from one root cannot masquerade as independent support;
- principal and audience visibility;
- cross-episode consolidation, contradiction reviews and reversible projections;
- governed procedure runs, outcome evidence and usefulness feedback;
- dependency-scoped capsule validation, bounded lifecycle evidence bundles and disposable memory-integrity evaluations;
- evaluation across raw sources, episodes and canonical retrieval under the same budget.

Experimental prediction-error reflection and procedure replay remain disabled until you enable their separate flags. Learned routing, latent memory and adaptive KV integration stay behind negative evidence gates until an implementation earns them.

### State, commitment and procedure controls

Current-state retrieval is opt-in: use `search ... --intent current_state` or `pack build ... --intent current_state`. Normal factual and historical retrieval retain their existing behaviour. A current-state result can be `current`, `unknown-validity`, `unresolved-conflict`, `unresolved-dependency`, `unresolved-inaccessible`, `invalid-cycle` or `historical`; unresolved material appears in a warning section.

Reflection candidates may declare `brain_commitment_action: persist|use-now|reverify|ask|quarantine` plus a reason and optional re-verification or clarification fields. `LLM_BRAIN_COMMITMENT_POLICY=shadow` is the default and records hash-bound derived decisions without changing legacy promotion. `enforce` routes persist through the existing promotion policy and keeps transient, validation and quarantine outcomes non-canonical. `legacy` disables the additional gate.

Reusable procedures can be prepared for an exact target:

```bash
./bin/llm-brain run prepare PROJECT_ID okf/procedures/release.md \
  --task "release checks" --principal hermes:default \
  --binding environment=staging --binding branch=main \
  --depends-on okf/claims/release-state.md \
  --verification "record the test report"
./bin/llm-brain run validate PROJECT_ID runs/prepared/CAPSULE.md --json
./bin/llm-brain run start PROJECT_ID okf/procedures/release.md \
  --capsule runs/prepared/CAPSULE.md --request-id release-1
```

Capsules bind the procedure hash, task, principal, bindings, declared dependencies, resolved evidence and verification requirements. Procedures can declare `brain_required_bindings`, `brain_applicability`, `brain_prerequisites` and `brain_verification` metadata. `run validate` is read-only and recomputes the recorded dependency closure; `run start --capsule` performs the same check immediately before creating the run. A changed, hidden, expired or unresolved dependency makes the capsule stale or blocked and requires a fresh preparation. Unrelated project changes do not invalidate it. Capsules are idempotent, non-canonical and never automatically executed or injected by Hermes.

Evidence retrieval is also explicit. `search` and `pack build` with `--intent evidence` can return bounded JSON `evidence_bundles` around selected records: current or historical versions, supporting evidence, conflicts, derivation and unresolved relationships. Each entry keeps its role/state, bounded excerpt and source hash; warnings and `incomplete` report hidden, unresolved or budget-limited links. The bundle follows only declared relationships; it does not merge records, infer agreement or change canonical memory. Hidden material is filtered before rendering.

The repository-only lifecycle evaluator runs twelve ground-truth scenario families at short (20-event) and long (200-event) checkpoints. It seeds facts, validity intervals, trust channels, visibility and as-of dates before applying updates, retractions, conflicts, poisoning, repair and procedure-capsule events. Each checkpoint compares six bounded modes: `none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`. It scores stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance alongside candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. Run it with `scripts/eval-lifecycle.py --cases CASES.json --output NEW_DIR --seed 0 --repeats 5`; an answer runner is optional, and model-answer accuracy remains unmeasured when it is absent. See [the development evaluation guide](docs/evaluation.md). Evaluation reports are disposable derived artefacts and never become memory.

## Safety boundaries

- Current source and explicit user instructions outrank stored memory.
- Capture never waits for reflection.
- Derived memory cannot outrank its strongest legitimate evidence.
- External, derived or poisoned text cannot gain authority through consolidation; high-risk procedure validation requires visible, current and custody-backed dependencies.
- Protected or ambiguous material stays in review.
- Canonical changes use promotion, supersession or retraction.
- Read-only search does not mutate memory.
- Lock recovery requires proof that the owner died.
- Indexes, vectors and context packs remain rebuildable.

Public archives exclude vault records, task captures, local usernames, home-directory paths, private network addresses and host identifiers. The packaging gate scans archive inputs for machine-specific data.

## Upgrade

Inspect the complete plan before applying it:

```bash
./bin/llm-brain upgrade check --all --host auto --target 0.6.3
./bin/llm-brain upgrade apply --all --host auto --target 0.6.3 --plan-hash HASH
./bin/llm-brain upgrade verify --receipt RECEIPT
```

Installation and ordinary memory use do not migrate a live vault. Keep the existing trusted marketplace or extension source during upgrades.

## Development

```bash
bash tests/release-readiness-self-check.sh
bash tests/release-readiness-self-check.sh --release
```

Read [the installation prompt](install_prompt.md) for agent-guided setup, [the architecture reference](references/architecture.md) for storage and authority boundaries, [the release guide](RELEASING.md) for publication gates, the [v0.6.3 release notes](docs/releases/v0.6.3.md) for this migration-free candidate, and the [Hermes/OpenClaw comparison report](docs/research/2026-09-06-hermes-openclaw-memory-comparison.md) for the next improvement goal.
