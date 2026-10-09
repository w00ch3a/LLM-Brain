# LLM-Brain

<p align="center">
  <img src="docs/assets/llm-brain-logo.png" alt="LLM-Brain" width="640">
</p>

[![Release](https://img.shields.io/github/v/release/w00ch3a/LLM-Brain)](https://github.com/w00ch3a/LLM-Brain/releases)
[![License](https://img.shields.io/github/license/w00ch3a/LLM-Brain)](LICENSE)
[![Storage](https://img.shields.io/badge/storage-Markdown-4B5563)](references/architecture.md)

**Durable, inspectable, filesystem-first memory for AI agents.**

LLM-Brain gives Codex, Claude Code, Gemini CLI, Hermes Agent and custom agents a shared project memory. It stores knowledge as Markdown, tracks the evidence behind each claim, and retrieves the right context before an agent starts work.

The infrastructure stays active. You do not have to invoke it, clear lock files or manage a memory queue during normal work.

<p align="center">
  <a href="#start-here">Start here</a> ·
  <a href="#why-agents-use-it">Why it matters</a> ·
  <a href="#a-60-second-cli-tour">CLI tour</a> ·
  <a href="#hermes-agent-memory-plugin">Hermes</a> ·
  <a href="#retrieval-and-memory-control">Retrieval</a> ·
  <a href="#governed-maintenance">Maintenance</a> ·
  <a href="#safety-boundaries">Safety</a>
</p>

## Start here

| If you want to… | Go to… |
|---|---|
| Install with safe defaults | [`install_prompt.md`](install_prompt.md) |
| Understand the storage and authority model | [`references/architecture.md`](references/architecture.md) |
| Connect Hermes memory | [`integrations/hermes/llm-brain/README.md`](integrations/hermes/llm-brain/README.md) |
| Run a bounded health review | [`skills/llm-brain-maintenance/SKILL.md`](skills/llm-brain-maintenance/SKILL.md) |
| Upgrade or publish safely | [`skills/llm-brain-upgrade/SKILL.md`](skills/llm-brain-upgrade/SKILL.md) and [`RELEASING.md`](RELEASING.md) |
| Contribute a docs or code change | [`CONTRIBUTING.md`](CONTRIBUTING.md) |

The README is the versioned front door. The linked guides hold the detailed
workflows, so installation and release behaviour stay reviewable with the
code instead of drifting in an unversioned wiki. Examples use placeholders;
this public documentation contains no vault records, credentials, hostnames
or user-specific filesystem paths.

## What's new in 0.8

Version 0.8 adds memory signals that stay deterministic, derived and
review-gated. Storage schema 3 and OKF v0.2 are unchanged, and no dependency
or vault migration is added.

- **BM25F lexical ranking.** Titles and frontmatter weigh more than body text.
  Scores are recomputed from canonical files on every query, so there is no
  index to drift. `LLM_BRAIN_LEXICAL_SCORER=legacy` restores the previous
  scorer.
- **File-aware recall.** Concepts may declare `brain_paths` globs (quote them:
  `brain_paths: ["src/api/**"]`). A task that names a matching file, or
  `--path FILE`, boosts those concepts.
- **Session brief.** `llm-brain brief` prints a size-capped summary of durable
  approved facts, due intentions and recent changes. The SessionStart hook
  injects it read-only and fail-open; `LLM_BRAIN_SESSION_BRIEF=0` turns it off.
- **Intentions.** `intention add` records "do X when Y" with a date, path,
  keyword or state-change trigger. Due intentions appear at the top of packs.
- **Usage, doctor and code anchors.** `usage` reports use counts and last-used
  dates from opt-in receipts and feedback. Maintenance adds advisory retention,
  orphan, duplicate and oversized signals; nothing is deleted. Concepts may
  declare `brain_code_anchors: ["path@commit"]`, and maintenance flags them for
  re-verification when git shows the file changed.
- **Spaced re-verification.** `stability show` derives an FSRS-style stability
  per record; `stability apply` explicitly moves `stale_after`.
- **Co-use links and review triage.** `association propose --write-review`
  proposes associations for records that keep appearing together in useful
  packs. `review triage` orders the queue: conflicts first, schema fits in a
  low-risk batch. Neither promotes anything automatically.
- **Diversity guard.** With `--usage-boost`, popular records get a modest boost
  and relevant, rarely used records keep reserved slots.
- **MCP server.** `llm-brain mcp serve --brain PATH` exposes search, packs,
  recall, status, brief and review-only capture over stdio. Each process
  serves one brain. See "Two people, one server, two brains".
- **Neural Expansion.** `llm-brain neural-expansion demo --open` opens an
  offline, read-only memory-graph viewer. Private real-vault export is
  experimental and opt-in.
- **Outcome evaluation.** `scripts/eval-outcome.py` runs small coding tasks
  with and without memory and scores them only with executable tests.

Index builds still batch OKF parsing and bind parsed facts to the admitted
source bytes. `llm-brain search --help` lists the supported options.

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

`VERSION` is the package-version authority; storage schema 3 and OKF v0.2 remain
the storage and canonical knowledge formats. The vault is
ordinary, portable Markdown and TSV, so it remains inspectable, copyable and
repairable without a database or hosted service.

### Shipped, experimental and deliberately out of scope

| Label | Boundary |
|---|---|
| **Shipped** | Markdown custody, OKF v0.2/schema 3, provenance and independent-root accounting, opt-in current-state resolution, evidence bundles, procedure capsule validation, repairable background work, and Hermes recall/capture. |
| **Experimental / opt-in** | Prediction-error reflection, procedure replay and commitment decisions. They are disabled by default and do not silently become canonical memory. |
| **Non-goal** | A hosted memory service, database, autonomous truth engine, universal prompt-injection defence, automatic procedure execution, learned routing, latent/KV memory or a claim that evaluation proves production deployment. |

### The lifecycle in one view

```text
capture → custody + episode → policy/review → canonical OKF
                                      ↓
                         lexical · vector · graph retrieval
                                      ↓
                     current/as-of/evidence-safe context pack → agent
                                      ↓
                         optional receipt or reviewed correction
```

### Feature grid

| Concern | What is inspectable |
|---|---|
| Truth and time | Current-state is explicit; validity gaps, conflicts, retractions and dependencies remain warnings, not invented certainty. |
| Provenance | Source hashes, lineage and independent roots distinguish corroboration from repeated copies. |
| Forgetting | `retract --preview` shows the exact target and confirmation token; only `--confirm TOKEN` records a reversible tombstone. |
| Maintenance | Bounded freshness, retention-candidate, conflict, work, receipt, index and provenance reports are derived and visibility-filtered; they never delete or promote memory. |
| Usefulness | `--receipt` and `feedback record` are opt-in derived records; reading memory never writes a receipt by default. A source is marked opened only after its visible custody bytes pass their expected SHA-256 check. |
| Portability and repair | Markdown/TSV custody, rebuildable indexes and staged migration/reconciliation keep recovery local and inspectable. |
| Hermes | Native provider recall and durable capture share the same bridge; Hermes never writes canonical `okf/` directly or executes capsules. |

## Why agents use it

| Need | LLM-Brain behaviour |
|---|---|
| Context survives sessions | Project memory lives on disk instead of inside one chat window. |
| Humans stay out of the plumbing | Agents retrieve context and capture authorised closeouts through host integrations. |
| Claims remain accountable | SHA-256 source custody, lineage, trust, temporal state and review decisions travel with memory. |
| Parallel agents keep working | Writers wait or recover proven-dead ownership; slow providers and embedders run outside the commit lease. |
| Old knowledge stays understandable | Supersession, retraction, conflicts and as-of retrieval preserve history. |
| Retrieval stays honest | Exact identifiers remain lexical, unavailable vector state reports degradation, and context packs expose their evidence. |

### Evidence before extra memory machinery

An explicit `--intent evidence` or `--intent current_state` pack puts unresolved state warnings ahead of resolved material. Under a tight budget it uses distinct, hash-verified source roots before repeated records from one source. Missing, hidden, changed or budget-omitted custody is marked incomplete, not silently counted as support. This checks bytes and visibility; it does **not** prove a source semantically supports an answer.

Retrieval receipts remain opt-in (`search --receipt`, `pack build --receipt`, or `bridge recall --receipt`). New receipts retain the existing JSONL fields and include identity version 2, with principal, intent, as-of and rendered selection in the idempotency key. Old receipts remain untouched. OKF v0.2 Markdown in storage schema 3 is still authoritative; bridge JSON and receipts are transport and derived audit data.

Hermes' normal capture stays non-blocking. Its optional checkpoint-required compression setting asks LLM-Brain for a durable bridge completion receipt before compression can discard direct messages; a queued outbox record alone is not that receipt. See the [Hermes guide](integrations/hermes/llm-brain/README.md) before enabling it, because the setting changes other Hermes compaction paths. OpenClaw remains an explicit staged observation, and Pi, Oh My Pi and Claude Code keep their own session mechanisms without becoming canonical memory writers.

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
- maintenance workflows through the progressive-disclosure
  `skills/llm-brain-maintenance/` skill.

Set `LLM_BRAIN_PASSIVE=0` when a session must opt out of automatic retrieval and closeout.

## First run

Global options go before the command:

```bash
brain="./bin/llm-brain --root /path/to/llm-brain-vault"

$brain project ensure /path/to/repository
$brain search PROJECT_ID "current task" --require-evidence
$brain pack build PROJECT_ID --task "current task" --budget-tokens 4000
```

### A 60-second CLI tour

```bash
# inspect the host and vault (read-only)
./bin/llm-brain detect
./bin/llm-brain doctor --strict

# register a repository, then retrieve evidence-backed context
./bin/llm-brain project ensure /path/to/repository
./bin/llm-brain search PROJECT_ID "release state" --intent current_state --require-evidence
./bin/llm-brain pack build PROJECT_ID --task "release state" --intent evidence --budget-tokens 2000

# inspect or write a bounded derived maintenance report
./bin/llm-brain maintenance preview PROJECT_ID --limit 20
./bin/llm-brain maintenance status PROJECT_ID --json
./bin/llm-brain maintenance run PROJECT_ID --limit 20

# preview a forgetting action; confirmation is deliberately separate
./bin/llm-brain retract PROJECT_ID okf/claims/example.md --reason "obsolete" --preview
./bin/llm-brain retract PROJECT_ID okf/claims/example.md --reason "obsolete" --confirm TOKEN
```

The final command is only an example: use the exact token and target returned by the preview. Retraction records a tombstone and audit event; it does not pretend that historical custody never existed.

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
├── maintenance/      # bounded derived health reports and schedule declarations
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

Build the package from this repository, or extract the release's `llm-brain-VERSION-hermes.tar.gz` (built by `scripts/package-hermes-archive.sh`), and place it in the active Hermes profile:

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

An empty `project_id` lets the plugin resolve the registered Hermes workspace or create a project for it. Optional settings, such as the local Laya recall filter and `context_engine_registration`, are off unless you add them; see the [Hermes plugin guide](integrations/hermes/llm-brain/README.md#opt-in-settings). Multiple Hermes sessions can capture into the same project. They share short commit leases while provider calls and retrieval work continue outside those leases.

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
- evaluation across raw sources, episodes and canonical retrieval under the same budget;
- deterministic BM25F lexical scoring with `brain_paths` file-glob recall (`--path FILE`) and an opt-in usage boost with a diversity guard (`--usage-boost`, `LLM_BRAIN_DIVERSITY_RESERVE`, default 2);
- prospective memory: `intention add PROJECT_ID --action TEXT --trigger date:ISO|path:GLOB|keyword:WORD|state:STATE_KEY` records operational intentions (never canonical OKF) that appear first in packs when due.

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

### MCP server

`llm-brain mcp serve` runs a stdio MCP server (JSON-RPC 2.0, stdlib only). Its
tools are `brain_search`, `brain_pack_build`, `brain_recall`, `brain_status`,
`brain_brief` and `brain_capture`. Every tool calls the CLI, so locks, audit,
visibility and secret scanning are unchanged. Capture creates only source
custody, an episode and a *proposed* review item. `mcp serve --read-only`
removes capture. Example host configuration:

```json
{"mcpServers": {"llm-brain": {"command": "llm-brain", "args": ["mcp", "serve", "--brain", "/path/to/brain"]}}}
```

Each server process serves exactly one brain (vault root): `--brain PATH`,
else `--root`, else `LLM_BRAIN_ROOT`, else the platform default. The root is
resolved once at start-up and never changes. Tools have no root argument;
unknown arguments such as `root` or `brain` are rejected. Project ids
are validated, so `../` cannot leave the brain. `--project-id ID` narrows a
server to one project. Start-up refuses a brain that is missing, a symlink,
owned by another OS user, or writable by group/others, and warns if others can
read it. Child CLI calls see only the pinned root. They use a fresh 0700 scratch
directory per process, so there is no shared cache.

#### Two people, one server, two brains

Recommended setup: **one OS account and one brain per person, with one stdio
MCP process per person per brain.** Nothing listens on a port.

1. Give each person their own account on the server (`alex`, `sam`) and a
   private brain in their home directory:

   ```bash
   sudo -u alex sh -c 'umask 077; mkdir -p ~/brain && chmod 700 ~/brain'
   sudo -u sam  sh -c 'umask 077; mkdir -p ~/brain && chmod 700 ~/brain'
   ```

2. Each person's MCP client starts its own server over SSH as that person, so
   SSH authenticates the person and OS permissions enforce the boundary. The
   remote shell expands `~` to that person's home directory:

   ```json
   {"mcpServers": {"llm-brain": {"command": "ssh",
     "args": ["-T", "alex@server", "~/.local/bin/llm-brain", "mcp", "serve", "--brain", "~/brain"]}}}
   ```

3. Optional: tie an SSH key to exactly one brain. Put this in
   `~alex/.ssh/authorized_keys` so the key can run nothing else:

   ```text
   command="~/.local/bin/llm-brain mcp serve --brain ~/brain",restrict ssh-ed25519 AAAA... alex-laptop
   ```

Each brain keeps its own locks (`BRAIN/.locks`), registry, hash-chained audit
log and receipts. Two processes never share state. Even a misconfigured client
cannot reach the other brain: the OS denies access, and the server refuses a
brain owned by another user. `tests/mcp-multi-brain-self-check.sh` covers these cases:
cross-brain project ids, root-override arguments, `../` ids, `--brain`
precedence over `LLM_BRAIN_ROOT`, project pins, unsafe or symlinked roots, and
an unchanged neighbouring brain.

If both brains must live under one OS account, list two entries with different
`--brain` paths. Isolation then depends on configuration, not the OS: any
process running as that account can read both brains. Use separate accounts
when the people do not fully trust each other.

There is no networked (HTTP/SSE) MCP server. A shared daemon would need its own
authentication, TLS, token storage and per-identity root mapping, and would run
as one OS user able to read every brain. That gives up the OS boundary that
makes the SSH setup safe, so it is not built. A forced-command SSH key already
maps an authenticated identity to exactly one brain.

### Governed maintenance

Maintenance is a bounded health view over one project, not another memory
store. It reports expiry and stale verification, unknown validity,
conflicts/dependencies, pending or failed work, receipt and index problems,
provenance gaps and retraction residuals. Findings are visibility-filtered and
labelled as review candidates; they recommend inspection or re-verification
without presenting unresolved material as truth.

```bash
./bin/llm-brain maintenance preview PROJECT_ID --principal agent-id --limit 20
./bin/llm-brain maintenance status PROJECT_ID --json
./bin/llm-brain maintenance run PROJECT_ID --limit 20
./bin/llm-brain maintenance schedule declare PROJECT_ID \
  --name "weekly memory review" --cadence weekly --runner hermes
./bin/llm-brain maintenance schedule disable PROJECT_ID
```

`preview` and `status` are read-only. `run` atomically writes only
`projects/PROJECT_ID/maintenance/latest.md`, whose `MaintenanceReport` is a
derived, non-canonical artefact. A schedule command records a declaration for
Hermes, Codex or cron; it does not install or activate a host scheduler. No
automatic deletion, retraction, promotion, index rebuild, daemon, database,
zvec engine, cloud backend or core dependency is introduced. Use `--strict`
when a maintenance caller wants `attention` or `blocked` findings to return
non-zero; ordinary retrieval remains fail-open. JSON status includes the
maintenance and schedule states, report state/hash, bounded counts/items,
recommendations and the reminder (`none`, `run-or-schedule`, `report-stale` or
`unavailable`).

Reports also carry a separate **advisory signals** section that never changes
maintenance health: retention candidates from usage evidence (only when
receipts or feedback exist), memory-doctor findings (orphans, likely duplicates,
oversized concepts), spaced re-verification suggestions and unverifiable code
anchors. Code drift from `brain_code_anchors` is the one new real finding: it
recommends re-verification when the project's registered source root shows the
anchored file changed since the recorded commit. Related read-only commands
are `usage PROJECT_ID`, `stability show PROJECT_ID`, `review triage PROJECT_ID`
and `association propose PROJECT_ID`.

The repository-only outcome harness runs small coding tasks with and without
LLM-Brain and scores them only with executable tests:
`scripts/eval-outcome.py --cases tests/fixtures/outcome/tasks.v1.json --output NEW_DIR [--runner EXECUTABLE]`.
The bundled reference runner is deterministic and only proves that the harness
measures memory-dependent outcomes; plug in a real agent with `--runner`.

The repository-only lifecycle evaluator runs thirteen ground-truth scenario families (including a rapid-update interference stress family) at short (20-event) and long (200-event) checkpoints. It seeds facts, validity intervals, trust channels, visibility and as-of dates before applying updates, retractions, conflicts, poisoning, repair and procedure-capsule events. Each checkpoint compares six bounded modes: `none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`. It scores stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance alongside candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. Run it with `scripts/eval-lifecycle.py --cases CASES.json --output NEW_DIR --seed 0 --repeats 5`; an answer runner is optional, and model-answer accuracy remains unmeasured when it is absent. See [the development evaluation guide](docs/evaluation.md). Evaluation reports are disposable derived artefacts and never become memory.

## Neural Expansion

Neural Expansion is a read-only, offline memory-graph viewer. It shows records
and their typed relations as an interactive graph, with search, status filters,
a detail panel and a keyboard-accessible list view. Each page is one
self-contained HTML file. It has no network calls, external assets, telemetry
or dependencies.

```bash
llm-brain neural-expansion demo --open     # bundled synthetic demo (alias: llm-brain viewer)
llm-brain neural-expansion path            # where the demo page lives
```

Real-vault pages are experimental and off by default. The export uses the
current index, applies lifecycle and principal visibility filtering before
serialisation, and writes one new `0600` file outside the vault:

```bash
LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 \
  llm-brain neural-expansion export PROJECT_ID --principal ID --output /private/dir/brain.html
```

`--principal` is a visibility filter, not authentication. Don't share,
sync or serve exported pages. See
[`neural-expansion/README.md`](neural-expansion/README.md) and
[`neural-expansion/PRIVACY.md`](neural-expansion/PRIVACY.md).

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

## Licence and responsibility

LLM-Brain is provided under the Apache License 2.0. The licence governs the grant of rights and its disclaimers and limitations; applicable law may limit how those terms operate. Use, configuration, validation, migration and deployment remain the user's responsibility. No documentation, test or evaluation result is a guarantee of correctness, availability, security, regulatory compliance or fitness for a particular purpose.

## Upgrade

Inspect the complete plan before applying it:

```bash
./bin/llm-brain upgrade check --all --host auto --target "$(tr -d '[:space:]' < VERSION)"
./bin/llm-brain upgrade apply --all --host auto --target "$(tr -d '[:space:]' < VERSION)" --plan-hash HASH
./bin/llm-brain upgrade verify --receipt RECEIPT
```

Installation and ordinary memory use do not migrate a live vault. Keep the existing trusted marketplace or extension source during upgrades.

Upgrade apply re-stages every vault, keeps a backup and a rollback tree, and
verifies the result before cutover. Records come through with the same values,
but YAML frontmatter may be re-serialised. A **standalone** install upgraded by
0.7.6 or older only receives `lib/okf.py`, because the old upgrader copies just
that file. Core commands still work on the partial tree. To finish the
install, run the new CLI once against the same release source:

```bash
llm-brain upgrade repair-standalone --source /path/to/llm-brain-0.8.2
```

It checks that the source matches the installed CLI byte for byte, then adds
only the missing helpers and Neural Expansion. Plugin and extension hosts
install the full package and don't need this step.
`tests/upgrade-from-previous-self-check.sh` runs the real 0.7.6 to current
upgrade on a populated synthetic vault.

## Development

```bash
bash tests/release-readiness-self-check.sh
bash tests/release-readiness-self-check.sh --release
```

Read [the installation prompt](install_prompt.md) for agent-guided setup, [the architecture reference](references/architecture.md) for storage and authority boundaries, [the release guide](RELEASING.md) for publication gates, and the [v0.8.2 release notes](docs/releases/v0.8.2.md) for this version. The [evidence-first host comparison](docs/research/2026-09-25-evidence-first-host-memory.md) explains the research behind the changes.
