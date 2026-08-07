# LLM-Brain v0.4 architecture reference

LLM-Brain v0.4 is a portable, filesystem-first memory lifecycle. `VERSION` is the package version; `schema.version` in a project is storage schema `3`. The canonical bundle implements Google Open Knowledge Format (OKF) v0.2. Schemas 1 and 2 remain readable and migrate only through an explicit staged migration or upgrade transaction.

## Data layers

| Layer | Location | Authority |
|---|---|---|
| Canonical semantic memory | `okf/` | Conformant OKF v0.2 source of truth |
| Episodic provenance | `episodes/YYYY-MM-DD/` | Append-only history; not truth |
| Source custody | `sources/` | Full-SHA-256 content-addressed copies |
| Exceptions | `review/`, `quarantine/` | Candidates, conflicts and redaction metadata |
| Derived retrieval | `indexes/` | Rebuildable |
| Derived consumption | `context-packs/`, `adapters/`, `exports/` | Rebuildable |

The root `okf/index.md` contains only `okf_version: "0.2"` frontmatter plus progressive-disclosure links. Project identity is the normal `okf/project.md` concept. `okf/log.md` uses newest-first `## YYYY-MM-DD` groups. Every other Markdown file under `okf/` is a concept with parseable YAML frontmatter and a non-empty `type`.

PyYAML parsing is isolated in `lib/okf.py`. It rejects duplicate keys and malformed standard families while preserving unknown types and fields. Unknown types, unknown keys, broken links and missing optional families remain consumable. Bash owns CLI policy, locking, custody, migration and host orchestration.

## Trust, lifecycle and retrieval

Schema-3 writers use the OKF `generated`, `verified`, `sources`, `status` and `stale_after` families plus useful `brain_*` extensions. Human verification is never inferred from approval. A verifier event is emitted only when a conformant actor and timestamp are actually recorded.

Consumers derive:

- no `verified` → `unverified`;
- only non-human verification → `machine-confirmed`;
- any `human:*` verification → `human-reviewed`;
- `today >= stale_after` → stale;
- absent `status` → stable.

Indexes, search results and context packs surface lifecycle, trust and freshness. Effective memory still honours LLM-Brain sensitivity, retraction, conflict and supersession controls. `Attested Computation` documents are validated, indexed, preserved and exported; LLM-Brain does not execute their computation, executor or attester.

Project writes use a durable directory lease under `.locks/`. Contenders wait for the owning process to finish; an owner proven dead is recovered only after its metadata is retained as a Markdown `LockRecovery` record. Writes keep temp-file-then-rename semantics and audit updates remain inside the lease. There is no lock-bypass mode. Vault migration and upgrade transition locks remain hard stops while owned by a live process because those operations replace or transform the vault as a whole; current releases record an owner so a dead transaction can be recovered, while legacy unowned transition locks remain a deliberate manual stop.

Index and embedding work is staged outside the project lease. Only the short derived-index commit and its audit event take the lease, so a slow embedder cannot block capture, review or canonical updates.

Provider-backed capture writes a Markdown `WorkItem` under each project's `requests/` directory before reflection. One-shot workers claim that item under the lease, call the provider outside it, and commit candidates and lifecycle state atomically. A dead worker is returned to `pending`; failed work remains durable and inspectable. Requests are derived and never canonical OKF truth.

The `eval run` command writes a derived Markdown report and TSV trace under `evaluations/`. It compares raw source/episode retrieval with canonical lexical, hybrid and graph paths, records unsupported strategies explicitly, and reports retrieval cost without mutating canonical memory.

Canonical records may carry optional temporal and lineage extensions: `brain_observed_at`, `brain_valid_from`, `brain_valid_to`, `brain_last_verified_at`, `brain_version_of`, `brain_derived_from` and `brain_authority_origin`. OKF `sources` remains the primary lineage field. Search applies known validity intervals only when current or as-of retrieval is requested; unknown intervals remain visible in historical mode. Provider or external-observation origin cannot silently increase source authority during automatic promotion.

The retrieval planner is deliberately a thin deterministic layer over the existing lexical, hybrid and graph paths. `search` and `pack build` accept intent, principal, evidence and exploratory hints without changing the legacy defaults: exact identifiers force lexical matching; historical intent includes superseded history; principal filters scoped records while retaining unscoped records; evidence requests follow canonical provenance to review, episodes and source custody; exploratory retrieval removes duplicate titles. Search metadata and context-pack frontmatter record the planner, temporal scope, evidence references and actual degraded/fallback mode. Supporting evidence is a derived pack section with hashes and excerpts; it never becomes canonical memory and is bounded by the requested budget.

## Provider and promotion policy

The core invokes only explicit trusted reflector, document embedder and query-embedder executables. Provider output is untrusted data and must pass bounded-file, YAML, secret, policy and custody checks.

Automatic promotion remains limited to low-risk, high-confidence claims, procedures and references with provable custody and no protected-domain wording. Healthcare, clinical, security, authentication, privacy, legal, finance, payment, production control, destructive migration, secret, restricted, ambiguous, skill and adapter material remains review-only.

## Migration and upgrade

`migrate check` is read-only and reports registry duplicates, review/scaffold counts, retraction candidates, source gaps and every OKF v0.2 transformation class. Schema-1/2 preflight accepts expected legacy reserved files, timestamps, citations and missing types while still rejecting malformed YAML and malformed standard families. Schema-3 staging and verification are strict.

`migrate stage --all --output PATH` is an internal primitive used by the upgrader. It copies one root, performs the schema-3 transformation and verifies the staged copy without touching the live root. Normal operators use `migrate apply --all`, which retains the existing sibling snapshot/rollback behaviour and writes tar backups beneath `LLM_BRAIN_BACKUP_ROOT`.

The public `upgrade` transaction:

1. discovers only configured roots;
2. hashes package and vault state into a deterministic plan;
3. installs the hash-locked PyYAML runtime;
4. updates the detected host through its native manager;
5. stages and verifies every vault before any cutover;
6. rechecks live hashes, cuts over sequentially and verifies each root;
7. restores every changed root and the prior local package on failure;
8. writes a non-secret receipt for verification or later rollback.

Codex package updates are source-aware. Git marketplaces use Codex's native marketplace refresh; local marketplaces are atomically replaced from the checksum-verified polyglot plugin archive before Codex refreshes its installed cache. Host inventory failures abort detection instead of silently falling back to a different installation type.

Package v0.4.0 reads schemas 1, 2 and 3. The automatic integration uses host-native skills, Claude `SessionStart`, Gemini context and an optional configured generic instruction file. It is active infrastructure with a passive user experience: the user does not need to invoke or manage it for each task. `LLM_BRAIN_PASSIVE=0` disables automatic use. No daemon or background scheduler exists.
