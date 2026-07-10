# LLM-Brain

LLM-Brain is a portable, filesystem-first memory lifecycle for coding agents:

`capture → provider reflection → deterministic policy → safe automatic promotion → retrieval → scoped context pack`

It keeps canonical knowledge as inspectable OKF Markdown, keeps raw source custody and episodes separate, and makes indexes, packs, adapters and exports rebuildable derived artefacts.

Version [`0.2.0`](VERSION) uses storage schema `2` while continuing to read schema `1` vaults. The runtime is Bash 3.2+ with standard macOS/Linux tools; Python standard library is build-time only.

## Quick start

```bash
# Inspect an existing root without changing it
bin/llm-brain --root /path/to/llm-brain doctor
bin/llm-brain --root /path/to/llm-brain stats

# Bootstrap only when authorised
bin/llm-brain --root /path/to/llm-brain project ensure /path/to/repository

# Capture, reflect and automatically promote only policy-safe candidates
bin/llm-brain --root /path/to/llm-brain ingest /path/to/source.md \
  --provider /path/to/trusted-reflector

# Build task-specific, approved-only context
bin/llm-brain --root /path/to/llm-brain pack build <project-id> \
  --agent codex --task "fix current migration"
```

`ingest-source PROJECT FILE [ROOT]` is the v0.1-compatible capture-only command. Use `--capture-only` or `--manual-only` to suppress reflection for an emergency or investigation. The core never calls a model or network service itself: a trusted local provider is an explicit executable.

## What promotes automatically

Only a low-risk claim, procedure or reference with confidence at least `0.90`, clean secret scan, valid provider ID/version, exact provenance and no conflict can auto-promote. Protected domains—clinical, security, authentication, privacy, legal, finance/payment, production control, destructive migration and secrets—remain exceptions. Retractions create tombstones; canonical history is not silently deleted.

Further implementation detail is in [the architecture reference](references/architecture.md). The agent-facing operating contract is in [SKILL.md](SKILL.md).

## Commands

```text
root list|ensure|disable PATH
detect
project ensure [SOURCE_ROOT] [--id ID] [--alias ALIAS]
topic add PROJECT_ID TITLE [--id ID] [--sensitivity LEVEL]
ingest FILE [--topic ID] [--capture-only|--manual-only] [--provider EXECUTABLE]
ingest-source PROJECT_ID FILE [ROOT]
reflect list|prepare|submit|run PROJECT_ID [--provider EXECUTABLE]
review list|show|decide PROJECT_ID ...
validate-source PROJECT_ID CANONICAL_ID FILE --reason TEXT
retract PROJECT_ID CANONICAL_ID --reason TEXT
index build|status PROJECT_ID [--embedder EXECUTABLE]
search PROJECT_ID QUERY ...
pack build PROJECT_ID --task TEXT ...
adapters build PROJECT_ID [--agent NAME|all]
export okf|knowledge-catalog|bundle PROJECT_ID
import bundle FILE --dry-run|--apply [--project-id ID]
map, secret-scan, stats, doctor, lint
migrate check|apply|verify
migrate reconcile-sources PROJECT_ID [--finalise-missing --reason TEXT]
```

Read-only commands do not create directories, write audit logs or rebuild derived artefacts. `migrate apply --all` is an explicit staging/rollback operation—not a normal command side effect.

Source reconciliation never substitutes current bytes for a historical hash. It can recover an exact SHA-256 or legacy MD5 match, revalidate an effective canonical item from a current authoritative source, or explicitly finalise an exhaustively searched gap as unrecoverable when no effective canonical item depends on it. Each mutation is locked and written to the hash-chained audit.

## Packages and local installation

Build deterministic direct-skill and Codex-plugin archives:

```bash
scripts/package-ai-skill.sh
```

The command builds each archive twice, requires byte-identical output, checks archive layout, extracts it and runs the packaged CLI’s version/help checks. It writes ignored artefacts beneath `dist/`.

Install the direct skill by extracting it under your agent’s skill root, for example `~/.codex/skills/llm-brain/`.

Install the personal Codex plugin by extracting it beneath `~/plugins/llm-brain/`, adding or updating the local marketplace entry, then running:

```bash
codex plugin add llm-brain@personal
```

## Verification

```bash
bash -n bin/llm-brain
tests/self-check.sh
tests/v2-self-check.sh
scripts/package-ai-skill.sh
```

See [RELEASING.md](RELEASING.md) for release gates and [SECURITY.md](SECURITY.md) for reporting boundaries.
