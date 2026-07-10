# LLM-Brain

LLM-Brain is a portable, filesystem-first memory lifecycle for software projects.

`capture → provider reflection → deterministic policy → approved memory → retrieval → scoped context`

Version [`0.2.0`](VERSION) stores durable knowledge as inspectable OKF Markdown, keeps source custody and episodes separate from canonical memory, and rebuilds indexes, exports and context packs from that durable layer. It runs on Bash 3.2+ with standard macOS/Linux tools; Python standard library is used only to build the release archive.

## Quick start

```bash
# Inspect an existing root without changes
bin/llm-brain --root /path/to/brain doctor
bin/llm-brain --root /path/to/brain stats

# Create project storage only when authorised
bin/llm-brain --root /path/to/brain project ensure /path/to/repository

# Capture source and optionally invoke an explicit local reflector
bin/llm-brain --root /path/to/brain ingest /path/to/source.md \
  --provider /path/to/trusted-reflector

# Build an approved-only context pack
bin/llm-brain --root /path/to/brain pack build <project-id> \
  --agent generic --task "current task"
```

The core makes no network calls. A reflector or embedder is an explicit local executable; do not configure one you do not trust with source material.

## Safety model

Automatic promotion requires a low-risk claim, procedure or reference; confidence of at least `0.90`; clean secret scanning; provider ID/version; exact provenance; and no conflict. Clinical, security, authentication, privacy, legal, financial, production-control, destructive-migration and secret-related material stays in review. Retractions create tombstones instead of silently deleting history.

Source reconciliation never substitutes current bytes for a historical hash. It recovers exact SHA-256 or legacy MD5 matches, revalidates effective canonical memory from current authority, or records an exhaustively searched source gap as unrecoverable only when no effective canonical item depends on it.

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
adapters build PROJECT_ID [--agent generic|all]
export okf|knowledge-catalog|bundle PROJECT_ID
import bundle FILE --dry-run|--apply [--project-id ID]
map, secret-scan, stats, doctor, lint
migrate check|apply|verify
migrate reconcile-sources PROJECT_ID [--finalise-missing --reason TEXT]
```

Read-only commands do not create directories, write audit records or rebuild derived artefacts. `migrate apply --all` is an explicit staging/rollback operation, never a normal side effect.

## Standalone package

```bash
scripts/package-ai-skill.sh
```

The command builds one deterministic standalone archive, checks archive members, extracts it and runs the packaged CLI’s version and help checks. The archive contains the CLI, skill contract, architecture reference, licence and version file; it contains no vendor-specific integration metadata.

## Verification and documentation

```bash
bash -n bin/llm-brain
tests/self-check.sh
tests/v2-self-check.sh
scripts/package-ai-skill.sh
```

See [SKILL.md](SKILL.md) for operating rules, [references/architecture.md](references/architecture.md) for the storage model, [RELEASING.md](RELEASING.md) for release gates and [SECURITY.md](SECURITY.md) for reporting boundaries.
