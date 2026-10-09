# Changelog

## Unreleased

- Fixed `index build` on filesystems without symlink support (CIFS/SMB
  mounts without `mfsymlinks`): compatibility aliases fall back to copies
  instead of aborting after publication and leaving rebuild state stuck at
  `building`.
- Fixed `index build` (and other audited writes) aborting on legacy projects
  that have no `audit.v2.tsv` yet; the hash chain now starts fresh.
- Development continues after the v0.7.1 release; no live-vault mutation is
  implied.
- Documented the shipped schema-3/OKF-v0.2 lifecycle, provenance and independent-root accounting.
- Documented opt-in receipts and preview/confirm tombstone retraction; no automatic forgetting or receipt writes.
- Clarified Hermes' unchanged factual-prefetch/native-compressor defaults and evaluation-only experimental boundaries.

## 0.8.1 - 2026-10-09

- Fixed stale-lock recovery on GNU/Linux: `lock_mtime` mixed `stat -f`
  filesystem output into the timestamp, so ownerless locks were never stale.
- Fixed `pack build` failing with "File name too long" for long `--task` text.
- Hermes plugin: opt-in local Laya recall filter (`laya_url`, fail-open,
  local/private endpoints only); bridge timeouts now stop the whole process
  group, and lock waits are capped at 2 seconds by default;
  `context_engine_registration: when-selected`; setup keeps other
  integrations' keys in `llm-brain.json`; AWS key redaction. The six selector
  keys are unchanged.
- Added `scripts/package-hermes-archive.sh` for a reproducible Hermes release
  archive, checked by the release gate.
- Added the repository-only real-agent evaluation suite in `evals/real/`.

## 0.8.0 - 2026-10-09

- Added deterministic stdlib BM25F lexical scoring (legacy scorer kept behind
  `LLM_BRAIN_LEXICAL_SCORER=legacy`) and `brain_paths` glob recall via task
  text or `--path`.
- Added a size-capped `brief` command, injected read-only by the SessionStart
  hook (`LLM_BRAIN_SESSION_BRIEF=0` opts out).
- Added operational intentions with date, path, keyword and state triggers;
  due intentions lead context packs.
- Added `usage`, advisory maintenance signals (retention, orphans, duplicates,
  oversized, spaced review) and `path@commit` code anchors with code-drift
  re-verification findings.
- Added FSRS-style `stability show` and audited `stability apply`.
- Added co-use `association propose`, schema-fit `review triage`, and an opt-in
  usage boost with a diversity guard.
- Added `mcp serve` (stdio MCP, review-only capture), the outcome harness
  `scripts/eval-outcome.py`, and a lifecycle interference family.
- Added Neural Expansion, an offline read-only memory-graph viewer
  (`neural-expansion demo|path`, alias `viewer`). It ships only a synthetic
  demo. Private, principal-filtered real-vault export is experimental and needs
  `LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1`.
- MCP servers are pinned to one brain: `mcp serve --brain PATH [--project-id
  ID]`. Root-override arguments, foreign-owned or group/world-writable roots,
  symlinked roots and traversal ids are refused. Documented the "two people,
  one server, two brains" SSH setup.
- Added `upgrade repair-standalone --source DIR`. It completes standalone
  trees written by 0.7.6-or-older upgraders, which copy only `lib/okf.py`.
  Core commands now fail open when a newer helper is missing.
- Fixed upgrade re-staging, which minted a duplicate, double-prefixed custody
  copy for sources already in `sources/`.
- Fixed an unbound variable in `import replication --dry-run`.
- Preserved schema 3, OKF v0.2, review gates and dependencies; no vault
  migration.

## 0.7.6 - 2026-10-02

- Batched request-local OKF facts during index preparation with source-byte
  binding and under-lock inventory, path, visibility and hash rechecks.
- Added search help and clean missing-argument diagnostics.
- Added retrieval guidance for exact names, aliases, root/index coverage,
  evidence recency and current execution-context access checks.
- Preserved schema 3, OKF v0.2 and existing dependencies; no vault migration.


# 0.7.1 - 2026-09-13

- Added governed maintenance previews, status, derived reports and explicit
  host-native schedule declarations without automatic deletion, promotion or
  scheduler installation.
- Added visibility-filtered freshness, work, receipt, index, provenance and
  retraction diagnostics, plus a progressive-disclosure maintenance skill.
- Refreshed the README with a navigation bar, documentation map, release
  guidance and privacy-safe public examples.
- Preserved schema 3, OKF v0.2, factual retrieval defaults, Hermes contracts,
  fail-open behaviour and migration-free upgrades.

# 0.7.0 - local candidate

- Added migration-free release documentation for opt-in receipts and
  preview/confirm tombstone retraction interfaces.
- Documented portability and evaluation limits, including unmeasured
  model-answer accuracy without a trusted local answer runner.
- Preserved Hermes defaults and fail-open boundaries; no published release is
  claimed.

# 0.6.3 - 2026-09-07

- Prepared the candidate release with version-controlled package metadata and
  release checks that derive the moving release path from `VERSION`.
- Preserved the filesystem-first, schema-3, Hermes-compatible lifecycle and
  migration-free upgrade boundaries.

# 0.6.2 - 2026-09-06

## Research-driven lifecycle safety

- Added deterministic current-state resolution with bounded dependency,
  supersession, validity, visibility and conflict handling.
- Added hash-bound commitment decisions, independent-source accounting and
  target-bound procedure capsules with read-only validation.
- Added explicit lifecycle evidence bundles, warning-first incomplete results,
  poisoning/repair regressions and the repository-only longitudinal evaluator.
- Preserved schema 3, factual retrieval defaults, Hermes provider/context-engine
  contracts, fail-open behaviour and migration-free upgrades.

## Release verification

- Added release-readiness checks for compatibility, safe upgrades, package
  reproducibility, documentation, supported Hermes source and version parity.
- No live-vault migration, daemon, database, model training or new runtime
  dependency is introduced.

# 0.6.1 - 2026-08-25

- Packaged the state-safe memory, commitment-policy and target-bound procedure work with the complete release-readiness gate.
- Preserved schema 3, factual Hermes defaults, native compressor behaviour, legacy bridge fields and migration-free upgrades.
- Added deterministic compatibility, upgrade, packaging and presentation checks for local and Hermes installations.

# 0.6.0 - 2026-08-25

- Added opt-in state resolution, independent-source accounting, commitment policies and target-bound procedure capsules.
- Preserved schema 3, factual Hermes defaults, native compressor behaviour and legacy bridge fields; no migration or new dependency.
- Added release gate and compatibility documentation for the Hermes memory selector.

## 0.5.3 - 2026-08-13

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
