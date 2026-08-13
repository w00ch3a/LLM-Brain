# Changelog

## Unreleased

- Improved Hermes conflict retrieval by indexing user content separately from assistant text, preserving temporal alternatives and principal boundaries, and rebuilding stale derived evidence indexes from source custody.
- Added dynamic, static and conditional answer guidance plus bridge provenance fields for observed time, source hash, principal and user-only excerpts.
- Extended Hermes regression coverage for employer, employment, marital, children and sibling conflicts, repeated evidence caps, lexical fallback and deterministic index rebuilds.

## 0.4.0 - 2026-07-31

See the [v0.4.0 release review](docs/releases/v0.4.0.md) for defect classification, root causes, verification and lessons learned.

- Upgraded canonical storage to schema 3 and Google Open Knowledge Format v0.2.
- Added strict PyYAML validation, legacy timestamp/citation migration, standard trust/lifecycle/freshness fields and Attested Computation interoperability.
- Added automatic Codex, Claude Code, Gemini CLI and generic-agent integration, giving users hands-off memory with an explicit opt-out.
- Added the callable `llm-brain-upgrade` skill and deterministic package-and-all-vault upgrade, verification and rollback commands.
- Blocked normal vault writes while an upgrade or migration owns the vault-wide transition lock.
- Preserved terminal unrecoverable source-reconciliation records exactly when migration rebuilds project ledgers.
- Made Codex upgrades source-aware: local marketplaces consume the verified plugin archive, Git marketplaces refresh natively, and failed host inspection aborts safely.
- Clarified in every host manifest that LLM-Brain operates automatically while only the user experience is passive.
- Added reproducible polyglot-plugin and standalone archives with pinned dependency checksums.
- Removed machine-specific paths from public defaults and release documentation.

## 0.3.0 - 2026-07-14

- Made index freshness and retrieval metadata truthful.
- Added optional deterministic graph expansion, historical retrieval and explain output.
- Added opt-in hybrid lexical/semantic retrieval with explicit query embedders and visible lexical fallback.
- Added retrieval regression fixtures for ranking, graph links, conflicts, supersession and pack metadata.

## 0.2.0 - 2026-07-10

- Replaced the minimal reference CLI with a schema-v2 filesystem lifecycle.
- Added trusted-provider reflection, custody-backed automatic promotion, review/retraction controls and hash-chained audit records.
- Added lexical/graph indexes, validated optional embeddings, context packs, adapters and portable exports/imports.
- Added staging/rollback migration tooling with exact scaffold reconciliation, legacy-MD5 custody recovery, current-authority canonical revalidation and audited unrecoverable source-gap finalisation.
- Added v2 runtime coverage, deterministic standalone packaging and release documentation.

## 0.1.0

- Initial filesystem-first skill and v0.1-compatible custody CLI.
