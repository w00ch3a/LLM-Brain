# LLM-Brain

Passive, filesystem-first durable memory for coding agents, stored as human-readable [Google Open Knowledge Format (OKF) v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/3fcbb9f828c2f23d109c855ee403c3a4c81f3a96/okf/SPEC.md).

LLM-Brain gives Codex, Claude Code, Gemini CLI and generic agents governed project memory without requiring the user to ask for it on every task. Canonical knowledge remains inspectable Markdown; episodes, source custody, review, audit, indexes and context packs preserve how that knowledge was produced and used.

## What it provides

- OKF v0.2 concepts with provenance, trust, lifecycle and freshness.
- Passive preflight retrieval and authorised closeout capture.
- Source custody, deterministic promotion policy, conflicts and retractions.
- Lexical, graph and optional local-vector retrieval with scoped context packs.
- `Attested Computation` interoperability without arbitrary code execution.
- Transactional package-and-vault upgrades with verified rollback receipts.

## Install

Clone the repository and run the Bash CLI directly; there is no application requirements file:

```bash
git clone https://github.com/w00ch3a/LLM-Brain.git
cd LLM-Brain
python3 -m venv .venv
.venv/bin/pip install --require-hashes --no-binary PyYAML -r requirements-okf.lock
export LLM_BRAIN_OKF_PYTHON="$PWD/.venv/bin/python"
./bin/llm-brain --version
```

Packaged installations bootstrap the same pinned PyYAML runtime during `llm-brain upgrade apply`.

The polyglot plugin archive supports:

- Codex through `.codex-plugin/plugin.json`;
- Claude Code through `.claude-plugin/`, `hooks/` and native plugin updates;
- Gemini CLI through `gemini-extension.json` and `GEMINI.md`;
- generic agents through `adapters/generic.md`.

Set `LLM_BRAIN_PASSIVE=0` to opt out of passive retrieval and closeout. LLM-Brain does not run a daemon.

## Privacy

Public source and release archives contain no vault records, task captures, local usernames, home-directory paths, private network addresses or host identifiers. Vaults, receipts, backups and generated runtime state remain outside the repository. The packaging gate rejects literal user-home paths and private IPv4 addresses.

## Use

Global options precede the command:

```bash
./bin/llm-brain --root /path/to/llm-brain project ensure /path/to/repository
./bin/llm-brain --root /path/to/llm-brain search PROJECT_ID "current task"
./bin/llm-brain --root /path/to/llm-brain pack build PROJECT_ID --task "current task"
```

Upgrade the installed package and every configured vault:

```bash
./bin/llm-brain upgrade check --all --host auto --target 0.4.0
# Confirm the complete output once, then:
./bin/llm-brain upgrade apply --all --host auto --target 0.4.0 --plan-hash HASH
./bin/llm-brain upgrade verify --receipt RECEIPT
```

Existing v0.3.1 users need one native host refresh to receive the `llm-brain-upgrade` skill. Live-vault migration is never performed by installation or ordinary memory use.

```bash
codex plugin marketplace upgrade MARKETPLACE
codex plugin add llm-brain@MARKETPLACE
# or
claude plugin update llm-brain@MARKETPLACE
# or
gemini extensions update llm-brain
```

Keep the existing trusted marketplace or extension source; do not silently switch sources during an upgrade. Start a new or reloaded host session, then ask the agent to “upgrade LLM-Brain” for the single-confirmation workflow.

See [the architecture reference](references/architecture.md) for storage and safety boundaries and [the release guide](RELEASING.md) for validation and publication.
