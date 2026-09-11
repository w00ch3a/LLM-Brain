# LLM-Brain v0.7.0 architecture reference (local candidate)

LLM-Brain v0.7.0 is the current local release candidate for a portable, filesystem-first memory lifecycle. `VERSION` is the package version; `schema.version` in a project is storage schema `3`. The canonical bundle implements Google Open Knowledge Format (OKF) v0.2. Schemas 1 and 2 remain readable and migrate only through an explicit staged migration or upgrade transaction. Markdown and TSV remain the inspectable recovery surface; indexes, packs, receipts and other derived artefacts are never canonical truth.

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

Captured episodes also receive a derived `ReflectionSchedule` under `reflection/scheduler/`. The selective scheduler is deterministic and conservative: explicit corrections, durable decisions, requirements, procedures, outcomes, contradictions and authoritative changes are immediate; only obvious low-value transients, already-reflected duplicates or pending-work duplicates are deferred. `LLM_BRAIN_REFLECTION_POLICY=legacy` preserves reflect-all behaviour during evaluation. Capture remains independent of the scheduler, and every decision/reason is inspectable Markdown plus an audit event.

Procedure execution uses `runs/` working records and append-only `runs/outcomes/` evidence. `ProcedureRun` records can carry a branch, obligations and verification state; `ProcedureOutcome` records carry status, observed time, evidence references and hashes. These records are deliberately non-canonical: durable procedural conclusions still require the existing review, promotion, supersession or retraction path.

Reconciliation recognises only explicit evidence markers such as `CONTRADICTS: okf/claims/item.md`. It creates a non-canonical `ReviewItem` with recalled/new hashes, a source-span marker, `brain_prediction_error` and `brain_version_of`; canonical memory remains unchanged until an existing governed decision is made. Evidence projections under `projections/` provide bounded summary/detail resolutions keyed by source hash and can be retracted through a Markdown tombstone, preserving reversibility and custody.

Optional principal/audience fields provide scoped visibility without making unscoped records disappear. `RetrievalFeedback` records bind a usefulness judgement to an exact pack hash and principal. `AssociativeProjection` records bind two exact evidence hashes as a derived `associates` relation; both artefacts are inspectable, idempotent and retractable, and neither can amplify authority or become canonical truth.

Experimental boundaries are explicit and disabled by default. Prediction records can measure exact expected/observed mismatch and, when enabled, feed an explicit reconsolidation review; procedure replay produces a derived plan linked to a prior outcome and never executes it. Goal allocation, causal selection, learned routing, latent memory, adaptive KV context and multimodal reconstruction remain negative evidence-gate entries rather than speculative implementation. No learned or latent state is canonical.

The existing `eval run` command writes a derived Markdown report and TSV trace under `evaluations/`. It compares raw source/episode retrieval with canonical lexical, configured vector, hybrid and graph paths and reports retrieval cost without mutating canonical memory. The repository-only ground-truth-first lifecycle harness (`scripts/eval-lifecycle.py`) runs twelve disposable scenario families at 20-event and 200-event checkpoints. It seeds facts, validity intervals, trust channels and visibility before updates, retractions, conflicts, poisoning, repair and procedure-capsule events. Checkpoints compare six modes—`none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`—and score stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance, together with candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. Evaluation identity binds cases, seed/repetitions, canonical history, index state and configured executable hashes; mismatched output directories are rejected. An optional answer runner adds model-answer outcomes; it is a trusted local executable with no OS sandbox requirement, and without one model-answer accuracy is unmeasured. See `docs/evaluation.md` for the bounded case and runner contract.

Canonical records may carry optional temporal and lineage extensions: `brain_observed_at`, `brain_valid_from`, `brain_valid_to`, `brain_last_verified_at`, `brain_version_of`, `brain_derived_from`, `brain_depends_on`, `brain_state_key`, `brain_supports` and `brain_authority_origin`. OKF `sources` remains the primary lineage field. Search applies known validity intervals only when current or as-of retrieval is requested; unknown intervals remain visible in historical mode. Provider or external-observation origin cannot silently increase source authority during automatic promotion.

## State resolution and evidence independence

`--intent current_state` is the only mode that resolves evolving state. It groups effective records by optional `brain_state_key`, honours validity intervals, retractions, deprecation, principal visibility, exact `brain_supersedes`/`brain_version_of` chains and `brain_depends_on` references. Lineage traversal is cycle-detected and capped at 32 hops. The resolver returns `current`, `unknown-validity`, `unresolved-conflict`, `unresolved-dependency`, `unresolved-inaccessible`, `invalid-cycle` or `historical`; factual and historical retrieval remain unchanged. Context packs and bridge context put anything other than `current` in a warning section. Missing validity is uncertainty, not an inferred date.

For the selected top 20 results, derived custody, episode provenance and `brain_derived_from` references are followed to root hashes with an eight-level, cycle-safe bound. Records sharing a root are one evidence group; unknown provenance is unconfirmed. `--explain`, bridge JSON and packs expose `evidence_group`, `independent_source_count`, `correlated_record_count` and `provenance_state`. Restricted paths, titles and hashes are never added to visible explanations.

Evidence intent may expand each selected canonical record into a bounded lifecycle `evidence_bundles` result. Expansion follows explicit `brain_supports`, `brain_conflicts`, `brain_supersedes`, `brain_version_of`, `brain_derived_from` and `brain_depends_on` links, including safe reverse links where needed to show a successor or supporting record. It is deterministic, cycle-safe and budgeted; each bundle preserves role, state, bounded excerpt and source hash, with `warnings` and `incomplete` reporting hidden, unresolved, truncated or budget-limited relationships. It never treats a shared state key as a replacement relation, invents agreement, or rewrites canonical memory. Visibility is applied to every visited record, so inaccessible evidence cannot leak through counts, paths, titles or hashes.

## Commitment decisions and procedure capsules

Candidate metadata can request `persist`, `use-now`, `reverify`, `ask` or `quarantine` with a reason, `brain_reverify_after` or clarification question. `LLM_BRAIN_COMMITMENT_POLICY` defaults to `shadow`: every accepted candidate receives a hash-bound derived `CommitmentDecision` under `reflection/commitments/`, while the existing promotion policy remains authoritative. `enforce` applies the transition gate (secret/custody/authority/staleness/conflict checks, then explicit action precedence); only custody, hashes, lineage, supersession and visibility are machine-verified. Semantic faithfulness remains a human concern. `use-now` is transient, `reverify`/`ask` are `needs-validation`, and quarantine never becomes canonical. Human review can override with an audited reason.

`run prepare` creates an idempotent `ProcedureCapsule` under `runs/prepared/`. It requires declared target bindings, a visible current procedure, exact procedure hash, target/principal/task, evidence references and verification requirements. Procedure metadata may declare `brain_required_bindings`, `brain_applicability`, `brain_prerequisites` and `brain_verification`; optional `--depends-on REF` values extend the procedure's declared `brain_depends_on` closure transitively. The capsule records locked `brain_dependency_refs`, per-reference `brain_dependency_hashes`, dependency state and a `brain_dependency_snapshot_hash_sha256`; the snapshot is part of capsule identity. `run validate --json` recomputes that closure without mutating the vault; `run start --capsule` repeats the check under the project lease immediately before creating the run, then applies capsule task/principal defaults and rejects conflicts. Changed, hidden, expired, inaccessible or unresolved dependencies invalidate the capsule, while unrelated project changes do not. A dependency-free legacy capsule retains its existing checks; a legacy capsule that depends on state records lacks the locked snapshot and must be re-prepared. Capsules and runs are non-canonical; Hermes never executes or injects them automatically.

## Hermes and host bridges

The standalone Hermes integration under `integrations/hermes/llm-brain/` uses
the host's `MemoryProvider` for automatic recall and durable turn observation.
It writes structured, secret-filtered Markdown outbox records under the
Hermes profile and hands them to `bridge capture`; it never writes `okf/`
directly. The optional `ContextEngine` subclasses Hermes' native
`ContextCompressor` and adds only request-scoped recall. When selected, it is
the sole recall injector and the memory provider continues capture. Its
`select_context()` result is deterministic, bounded and fail-open, and never
mutates persisted conversation history.

`bridge recall` and `bridge capture` are host-neutral JSON transport commands.
Project resolution uses a configured ID, the supplied workspace identity, or
automatic `project ensure`; all durable state remains Markdown and existing
project locks, atomic renames and idempotent custody rules remain authoritative.
Recall emits only complete UTF-8 Markdown blocks within the requested budget.
Restricted Hermes tool results retain their call lineage and full-result hash,
but no content-derived excerpt, path or outcome text.

The retrieval planner is deliberately a thin deterministic layer over the existing lexical, hybrid and graph paths. `search` and `pack build` accept intent, principal, evidence and exploratory hints without changing the legacy defaults: exact identifiers force lexical matching; historical intent includes superseded history; principal filters scoped records while retaining unscoped records; evidence requests follow canonical provenance to review, episodes and source custody; exploratory retrieval removes duplicate titles. Search metadata and context-pack frontmatter record the planner, temporal scope, evidence references and actual degraded/fallback mode. Supporting evidence is a derived pack section with hashes and excerpts; it never becomes canonical memory and is bounded by the requested budget.

## Provider and promotion policy

The core invokes only explicit trusted reflector, document embedder and query-embedder executables. Provider output is untrusted data and must pass bounded-file, YAML, secret, policy and custody checks.

Automatic promotion remains limited to low-risk, high-confidence claims, procedures and references with provable custody and no protected-domain wording. External or derived text cannot acquire direct authority through a summary or relation. Poisoning regressions exercise capture, admission, retrieval, simulated procedure validation, selective repair and preservation of unrelated provenance. Healthcare, clinical, security, authentication, privacy, legal, finance, payment, production control, destructive migration, secret, restricted, ambiguous, skill and adapter material remains review-only.

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

The v0.7.0 local candidate reads schemas 1, 2 and 3. The automatic integration uses host-native skills, Claude `SessionStart`, Gemini context and an optional configured generic instruction file. It is active infrastructure with a passive user experience: the user does not need to invoke or manage it for each task. `LLM_BRAIN_PASSIVE=0` disables automatic use. The four upgrades add no schema migration, daemon, model training, KV-cache integration, graph database or mandatory dependency.
Retraction is a two-step safety boundary: `retract --preview` resolves the exact canonical target and emits a confirmation token; `retract --confirm TOKEN` records the tombstone and audit event. A preview never mutates the vault, and retraction does not delete source custody or historical episodes. Search and pack receipts are opt-in derived records (`--receipt`); normal reads do not create them.
