# Universal LLM-Brain Beyond the Wiki
## Universal agent skill prompt
You are to design and implement a universal, repository-agnostic, language-agnostic “LLM-Brain” as a reusable skill that works across projects and also across a shared knowledge root.
Your job is to inspect the current repository and existing project context, then build the solution directly into the current project in the most native way possible, while keeping the design portable across stacks and runtimes.

High-level goal:
Create a durable memory and knowledge system that goes beyond an LLM wiki. Use OKF v0.1 as the canonical durable knowledge format, and build a full LLM-Brain around it with:
- canonical semantic memory,
- episodic memory,
- procedural memory,
- reflection and self-improving memory loops,
- review and approval workflow,
- provenance and conflict handling,
- hybrid retrieval,
- context-pack generation,
- multi-agent adapters,
- multi-root shared knowledge support.

Critical constraints:
- Be repository-agnostic and language-agnostic.
- Do not assume Python. Prefer the existing stack already present in this repository.
- If the repo is polyglot, put the core implementation where it best fits operationally, but keep the public interfaces language-neutral.
- Do not introduce a heavy new runtime unless truly necessary.
- Prefer standard library and lightweight dependencies unless there is a clear reason not to.
- Keep all storage formats inspectable and portable.
- The canonical durable layer must be filesystem-based and human-readable.
- Use OKF v0.1 as the canonical bundle format for semantic memory.
- The user may invoke this skill at the start of a new project or mid-thread as a request to create a brain section for a specific idea/topic/thread.

What to detect first:
- Detect whether this invocation means:
  1. bootstrap a new project brain,
  2. extend an existing project brain,
  3. create a scoped thread/topic addition under the current project brain.
- Infer project identity using:
  - git root,
  - repo name,
  - git remotes,
  - working directory,
  - existing AGENTS.md / CLAUDE.md / SKILL.md / MEMORY.md / docs,
  - and any already-existing LLM-Brain registry.
- Use deterministic project fingerprinting so multiple clones of the same repo map to one durable project identity when appropriate.
- If a current thread/topic is clearly narrower than the overall project, create a topic-scoped sub-brain instead of a whole new project brain.

Shared knowledge root requirements:
- Support multiple roots, with a default shared root.
- Create a registry that tracks:
  - projects,
  - aliases,
  - repo fingerprints,
  - roots,
  - ownership,
  - scope hierarchy,
  - adapter state,
  - migration version.
- The registry must be file-backed, inspectable, and safe to diff in git.

Canonical data model:
Build the system in layers.

Layer 1: episodic memory
- Append-only event records for:
  - conversations,
  - tool calls,
  - file edits,
  - tests run,
  - decisions,
  - user corrections,
  - extracted candidate claims,
  - candidate procedures,
  - candidate references.
- Ensure episodes store timestamps, actor, source, scope, and provenance pointers.
- Episodes are not the canonical truth layer.

Layer 2: semantic memory
- Canonical durable semantic memory must be stored as OKF bundles.
- Every semantic concept must be a Markdown file with YAML frontmatter.
- Use `index.md` and `log.md` where appropriate.
- Keep OKF conformant while allowing producer-defined extension fields for brain-specific metadata.
- Add companion conventions for:
  - project_id,
  - topic_id,
  - claim_id,
  - review_state,
  - confidence,
  - provenance,
  - conflict links,
  - sensitivity,
  - supersedes links,
  - source pointers,
  - updated_by,
  - last_validated_at.

Layer 3: procedural memory
- Generate agent skills and reusable procedures using the Agent Skills / SKILL.md pattern.
- Skills must be proposal-driven and reviewable before becoming active when risk is non-trivial.
- Keep focused skills small and specific.
- Avoid one giant monolithic skill document.
- Add routing descriptions designed for activation, not general docs.
- Include eval fixtures for skill routing and off-target negative examples.

Layer 4: retrieval memory
- Build hybrid retrieval over the canonical and episodic layers:
  - lexical search,
  - vector search,
  - graph/relationship search.
- Retrieval must support:
  - exact lookup,
  - semantic similarity,
  - multi-hop relation lookup,
  - source/provenance lookup,
  - recency filters,
  - scope filters,
  - sensitivity filters,
  - review-state filters.

Layer 5: governance
- Implement:
  - review queue,
  - approval workflow,
  - conflict detection,
  - provenance tracing,
  - secret scanning/redaction,
  - audit logs,
  - schema and migration versioning,
  - export/import,
  - access scoping,
  - safe deletion / tombstoning / retraction propagation.

Expected architecture:
Create a clear modular architecture with components for:
- project resolver,
- registry manager,
- OKF bundle manager,
- episode writer,
- claim extractor,
- procedure extractor,
- review queue,
- promotion engine,
- relation/graph builder,
- lexical indexer,
- vector indexer,
- context-pack builder,
- agent adapter generator,
- Knowledge Catalog exporter,
- secret scanner,
- migrations,
- tests/evals,
- CLI/API surfaces.

Repository-native implementation rules:
- First inspect the repo and determine the existing language/tooling.
- Reuse the existing stack if it is appropriate.
- If the repo already has a CLI pattern, integrate into that.
- If the repo already has tests, match the testing style.
- If the repo already has config conventions, follow them.
- If the repo has no clear stack, create a minimal portable implementation with:
  - filesystem-first storage,
  - a small local CLI,
  - clear separation between core logic and adapters.
- Do not rebuild the entire app if a sidecar module is more appropriate.

Core features to implement:
1. Project and topic detection
- Detect new project vs existing project vs scoped topic addition.
- Support explicit overrides from the user if later provided.
- Persist scope relationships in registry and OKF extensions.

2. OKF bundle creation
- Create canonical bundle structure for:
  - project bundle,
  - topic bundle,
  - references,
  - claims,
  - procedures,
  - episodes index,
  - review queue,
  - exports,
  - generated context packs.
- Auto-generate `index.md` progressively.
- Maintain `log.md` update history.

3. Reflection and self-improving memory loop
- Add asynchronous or deferred reflection pipeline that:
  - distils raw episodes into candidate claims/procedures,
  - deduplicates,
  - attaches provenance,
  - links entities,
  - detects conflicts,
  - routes to review or auto-promotion depending on policy.
- Auto-promotion must be conservative.
- High-risk or ambiguous items must go to review.

4. Claim and conflict management
- Build an explicit claim registry.
- Claims must support:
  - confidence,
  - source links,
  - conflict links,
  - supersedes links,
  - validation status,
  - review state.
- Never silently overwrite a claim because a newer one exists.
- Preserve contradiction history until resolved.

5. Knowledge graph / relation layer
- Build a lightweight graph layer over:
  - OKF links,
  - claim references,
  - shared entities,
  - project/topic hierarchy,
  - citation links,
  - procedure dependencies.
- Keep this graph derivable from the filesystem when possible.
- Do not make an external graph DB mandatory for the default path.

6. Retrieval indexes
- Build:
  - lexical index,
  - vector index,
  - derived relationship graph index.
- Make index providers swappable.
- Support local/offline-first defaults.
- Cache embeddings and support incremental re-indexing.
- Re-index only touched concepts when possible.

7. Context-pack API
- Implement task- and agent-specific context pack generation.
- A context pack is a derived view over the brain, not the source of truth.
- Support pack creation by:
  - agent type,
  - task,
  - token budget,
  - scope,
  - recency,
  - confidence threshold,
  - review filter.
- Packs should include only what is needed and provide expansion pointers.
- Add pack strategies for:
  - Codex,
  - Claude Code,
  - Hermes,
  - OpenClaw,
  - generic Agent Skills clients.

8. Multi-agent adapters
- Generate or update artifacts for:
  - `AGENTS.md`,
  - Agent Skills-compatible `SKILL.md` directories,
  - Claude Code-compatible project guidance if relevant,
  - Hermes-compatible skill/installable structures if relevant,
  - OpenClaw-compatible skill structures if relevant.
- Make these adapters derived artifacts generated from the canonical brain.
- Do not let adapters become the only source of truth.

9. Knowledge Catalog export
- Add exporter that maps OKF bundle content into a Knowledge Catalog / Documents Layout friendly export structure.
- Preserve file path identity.
- Ensure frontmatter and body can be transformed consistently.
- Document mapping rules and edge cases.

10. Secret scanner and redaction
- Implement source-custody and pre-promotion scan paths so secrets and sensitive tokens do not enter the brain or durable semantic memory.
- Quarantine sensitive candidate content.
- Store safe provenance that something was redacted without exposing the secret itself.
- Add tests for fake API keys and credentials.

11. Review workflow
- Add a review queue for:
  - promoted claims,
  - skill proposals,
  - conflicts,
  - redaction decisions,
  - migrations requiring attention.
- The queue must be inspectable in files.
- Support states like:
  - draft,
  - proposed,
  - approved,
  - rejected,
  - superseded,
  - needs-validation.
- Add CLI commands to inspect and operate on the queue.

12. Migrations and schema versioning
- Version:
  - registry schema,
  - brain extension schema,
  - index schema,
  - export schema.
- Add migration tooling.
- Add compatibility tests.

13. Offline-first and sync
- Treat local filesystem state as primary.
- Add optional support for syncing or pushing to additional remotes.
- Support multiple knowledge roots.
- Do not require cloud services for the default path.

14. Access scoping and security
- Add support for scope and sensitivity metadata.
- Prevent sensitive concepts from leaking into low-trust context packs.
- Make filtering part of retrieval and pack generation.
- Add audit logging for promotion, review, export, deletion, and redaction actions.

15. CLI
Provide a usable CLI or repo-native command surface for at least:
- init/bootstrap brain,
- detect scope,
- add topic,
- ingest source/current thread/context,
- reflect,
- review list/show/approve/reject,
- build indexes,
- build context pack,
- export OKF,
- export Knowledge Catalog,
- run secret scan,
- stats/doctor/map/lint,
- migrate.

Reference CLI baseline for this repository:
- The minimal Bash reference CLI currently provides `doctor`, `stats`, `ingest-source`, `map`, and `lint`.
- `ingest-source` must require an explicit project id, copy the source into that project, write a content hash sidecar, record an append-only episode, create a review item, append an audit log entry, and block likely secrets before custody.
- `map` must require an explicit valid project id and generate one project-level `INDEX.md` listing active folders, canonical files, and starting points. Do not create recursive index files for every subfolder unless measured navigation failures justify it. Generated maps must include a generated marker, refuse to overwrite human-authored `INDEX.md` files, and avoid leaking absolute registered source-root paths.
- `lint` must check project structure, source hash sidecars, and unresolved wikilinks. It should resolve mirror-project wikilinks through the project registry source root where available.
- Pending review items are governance backlog, not lint warnings by default. Report them as informational unless a specific release policy makes backlog itself a blocker.
- Keep this baseline tiny. Add richer commands only when they close a real workflow gap.

Implementation details and defaults:
- Prefer OKF for semantic memory.
- Store episodes separately from canonical OKF concepts.
- Use append-only logs where possible.
- Keep all generated files deterministic.
- Avoid hidden state.
- Prefer text and file-backed state over opaque DB-only state.
- Use a small embedded/local default for indexes if the current project does not already have infrastructure.
- Make vector and graph backends pluggable.
- Make embedding provider pluggable.
- Support local/open embedding models where practical.
- Cache embeddings by stable content hash.
- Add tombstones or retraction markers rather than destructive deletion when provenance matters.

Suggested filesystem shape:
Create an implementation-appropriate structure, but conceptually provide:
- per-project canonical bundle,
- optional per-topic scoped bundles,
- derived indexes,
- review queue,
- exports,
- adapters,
- docs,
- tests/evals.

What to generate in docs:
Create strong documentation that explains:
- mental model,
- context vs memory,
- episodic vs semantic vs procedural memory,
- promotion flow,
- review workflow,
- adapters,
- retrieval strategy,
- Knowledge Catalog export,
- safety model,
- migrations,
- how to add a new embedding or index backend,
- how to bootstrap a new project brain,
- how to create a scoped thread/topic brain.

Testing requirements:
Add meaningful automated tests and evals for:
- project identity resolution,
- scope detection,
- OKF conformant output,
- claim conflict detection,
- provenance preservation,
- secret redaction,
- review state transitions,
- context-pack generation,
- adapter generation,
- incremental indexing,
- export/import correctness,
- migration compatibility.
Also add routing/eval fixtures for generated skills:
- positive triggers,
- neighbour-confusion negatives,
- off-target negative cases.

Performance requirements:
- Make indexing incremental.
- Make reflection incremental.
- Avoid re-embedding unchanged content.
- Support large vaults without loading everything into memory.
- Use progressive disclosure in generated indexes and context packs.
- Keep derived artifacts rebuildable.

Delivery requirements:
- Inspect the repository first.
- Make a concrete implementation plan in files, then execute it.
- Build the system, not just a design doc.
- Add or update code, config, tests, and docs.
- If the repo lacks a suitable app surface, create a minimal but production-sane sidecar module.
- Show the final file tree and how to use the system.
- Include examples of:
  - new project bootstrap,
  - extending an existing project brain,
  - creating a scoped thread/topic addition,
  - building a context pack for Codex,
  - exporting to Knowledge Catalog.
- If tradeoffs are necessary, prefer:
  1. canonical durability,
  2. inspectability,
  3. safe promotion,
  4. portability,
  5. stack compatibility,
  6. performance.

Important design principle:
The LLM-Brain is not the prompt, not the transcript, and not a vendor-specific memory store.
The source of truth must be durable, inspectable, portable, and reviewable.
Everything agent-specific must be derived from that source of truth.

Now inspect the repo, choose the most native implementation path, and build the full solution end-to-end.
