# LLM-Brain research update — 2026-09-07

**Scope:** dated synthesis of the completed academic, Hermes, OpenClaw and LLM-Brain review lanes. The [2026-09-06 Hermes/OpenClaw comparison](2026-09-06-hermes-openclaw-memory-comparison.md) is preserved; this update narrows its claims and prioritises implementation work.

**Evidence labels:** **[Lane result]** is a result reported by the completed review lane; **[Stable]** is a tagged or official release/documentation claim; **[Main]** is evidence from an unreleased main-branch commit; **[Local]** is checked in this LLM-Brain repository; **[Inference]** is an implementation assessment, not a measured outcome.

**Cut-off:** the academic watch ended at 2026-09-06. External repositories and documentation are version-sensitive; stable-release claims and main-branch claims are kept separate.

## Executive answer

**[Lane result | 2026-09-07]** No qualifying new academic primary-source work after the 2026-09-06 cut-off was identified. The exact-cutoff `agent-memory-atlas/membench` commit `1857406` is retained as a near-miss engineering/benchmark reference, not as a new peer-reviewed result; its public repository location was not independently resolved in this pass. See the [MemBench primary paper](https://aclanthology.org/2025.findings-acl.989/) and the [Agent Memory Atlas repository](https://github.com/SynapseGrid-Labs/agent-memory-atlas) for the surrounding reference set.

The useful additions are operational: truthful partial/degraded retrieval and stable failure envelopes; bounded spill and size limits; duplicate-hook/registration ownership; atomic derived-index publication plus watcher/index health; benchmark identity and measurement; then custody-aware replication and a staged read-only OpenClaw bridge. These additions fit LLM-Brain's existing OKF/custody/authority/visibility boundaries and do not require replacing canonical Markdown with a graph database, daemon or hosted service. This is an **[Inference]** from the [LLM-Brain architecture](../../references/architecture.md), [retrieval contract](../../README.md#retrieval-and-memory-control), and [Hermes integration contract](../../integrations/hermes/llm-brain/README.md), not a cross-system quality result.

Do not describe semantic ranking, evidence disclosure, or export/import as wholly new: LLM-Brain already has lexical/vector/hybrid retrieval, deterministic reranking, bounded evidence bundles, summary/detail projections, canonical OKF bundle export/import, state/commitment/capsule controls, and a Hermes provider with an optional ContextEngine. The work below closes measured gaps around those capabilities rather than replacing them. **[Local]** [README retrieval](../../README.md#retrieval-and-memory-control), [architecture](../../references/architecture.md#state-resolution-and-evidence-independence), [CLI](../../bin/llm-brain), and [Hermes integration](../../integrations/hermes/llm-brain/README.md).

## Evidence ledger

### Academic and benchmark watch

- **[Lane result | 2026-09-07]** No qualifying new academic primary-source publication was found after 2026-09-06. This is a bounded negative result, not proof that no such work exists anywhere; the comparison is therefore not a literature claim.
- **[Near-miss | exact cut-off]** The supplied `agent-memory-atlas/membench@1857406` reference is useful as a benchmark/engineering lead but is not promoted to academic evidence. The supplied [exact-cutoff commit link](https://github.com/agent-memory-atlas/membench/commit/1857406) did not resolve publicly during this pass; see [limitations](#limitations-and-unresolved-citation-gaps).

### Hermes

- **[Stable | lane result]** Hermes stable `v0.21.0` was unchanged at the cut-off. The exact stable release URL was not independently resolved in this pass, so this remains lane evidence rather than a newly re-proven release claim. The official [memory-provider guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers/), [provider plug-in API](https://hermes-agent.nousresearch.com/docs/developer-guide/memory-provider-plugin/), and [MemoryProvider source](https://github.com/NousResearch/hermes-agent/blob/main/agent/memory_provider.py) define the lifecycle seam, checkpoint API, and non-blocking `sync_turn` contract.
- **[Main | 2026-09-07 review]** [`d932fa5`](https://github.com/NousResearch/hermes-agent/commit/d932fa5) spills oversized external prefetch output. This is evidence for bounded recall handling, not a stable `v0.21.0` feature.
- **[Main | 2026-09-07 review]** [`2ed33fb`](https://github.com/NousResearch/hermes-agent/commit/2ed33fb) keeps the spill work while dropping the registration-trust rework; treat the pair as main-branch design evidence, not as a release contract.
- **[Main | 2026-09-07 review]** [`684a2cf`](https://github.com/NousResearch/hermes-agent/commit/684a2cf) gives dual-kind memory hooks a single owner, while [`5bd439d`](https://github.com/NousResearch/hermes-agent/commit/5bd439d) keeps the fallback ownership in the ledger. Together they support an at-most-one-registration/duplicate-hook guard for an external provider.
- **[Main | 2026-09-07 review]** [`be58c276`](https://github.com/NousResearch/hermes-agent/commit/be58c276) adds provider-derived per-image token-cost calibration. It is evidence for a future optional modality-budget experiment, not authority for adding multimodal storage to LLM-Brain.

### OpenClaw

- **[Stable | lane result]** OpenClaw stable `2026.9.2` was unchanged at the cut-off. The official [2026.9.2 release notes](https://docs.openclaw.ai/releases/2026.9.2) and [memory overview](https://docs.openclaw.ai/concepts/memory) are the stable references; main-branch commits below must not be presented as release behaviour.
- **[Main | 2026-09-07 review]** [`4681f8d`](https://github.com/openclaw/openclaw/commit/4681f8d) adds partial-result handling with a visibility recheck; this is a useful model for fail-open-but-truthful retrieval envelopes.
- **[Main | 2026-09-07 review]** [`2a48854`](https://github.com/openclaw/openclaw/commit/2a48854) bounds asynchronous stale cleanup and publishes full rebuilds atomically; [`7969f49`](https://github.com/openclaw/openclaw/commit/7969f49) preserves exact-path precedence.
- **[Main | 2026-09-07 review]** [`563b155`](https://github.com/openclaw/openclaw/commit/563b155) exposes watcher-exhaustion diagnostics; [`d1e5a1`](https://github.com/openclaw/openclaw/commit/d1e5a1) supplies stable JSON failure envelopes; [`6277d6`](https://github.com/openclaw/openclaw/commit/6277d6) keeps migration descriptors read-only when repair is refused.
- **[Stable docs | reviewed]** OpenClaw documents search and stale-index warnings in [memory search](https://docs.openclaw.ai/concepts/memory-search), lineage and deletion in [memory provenance](https://docs.openclaw.ai/concepts/memory-provenance), thresholded consolidation in [Dreaming](https://docs.openclaw.ai/concepts/dreaming), and structured dashboards/OKF import in [memory-wiki](https://docs.openclaw.ai/plugins/memory-wiki). These are documented capabilities, not an independent integrity benchmark.

### LLM-Brain baseline

- **[Local candidate | 2026-09-07]** The repository `VERSION` is [`0.6.3`](../../VERSION); the candidate release notes are [`docs/releases/v0.6.3.md`](../releases/v0.6.3.md). Canonical OKF v0.2, SHA-256 custody, review boundaries, visibility, state resolution, provenance independence, commitment decisions and target-bound capsules are defined in the [architecture reference](../../references/architecture.md).
- **[Local | existing capability]** Retrieval already includes lexical, optional vector and hybrid paths, deterministic ranking, explicit graph/state/evidence intents, bounded evidence bundles, warning-first unresolved state, and a repository-only lifecycle evaluator. See [retrieval and memory control](../../README.md#retrieval-and-memory-control) and the [evaluation guide](../../docs/evaluation.md).
- **[Local | existing capability]** `export bundle`/`import bundle` already provide a canonical-OKF-only, per-file-hash path. They do not yet constitute a custody-aware replication ledger containing all source custody, episodes, tombstones and principal scope; extending them is P1 work, not a new export/import primitive. See the [reference CLI](../../bin/llm-brain) and [OKF architecture](../../references/architecture.md#data-layers).
- **[Local | existing capability]** The Hermes plug-in preserves `memory.provider: llm-brain`, the six configuration keys, native compression, a single recall injector, fail-open recall/capture boundaries, and optional explicit lifecycle intents. See the [Hermes integration guide](../../integrations/hermes/llm-brain/README.md).

## Prioritised implementation shortlist

### P0 — prove and harden the retrieval contract

#### P0.1 Benchmark identity and measurement

Reuse [`scripts/eval-lifecycle.py`](../../scripts/eval-lifecycle.py) and the [lifecycle evaluation contract](../../docs/evaluation.md); add black-box adapters only for the selected Hermes/OpenClaw/provider versions.

**Value and fit:** This is the highest-value missing evidence. It keeps canonical OKF, custody, authority, visibility and capsule semantics in LLM-Brain while measuring retrieval and lifecycle behaviour separately from model answers. **[Inference]** The external systems are comparison subjects, not authorities.

**Hermes compatibility:** Run provider-prefetch and ContextEngine as separate modes. Preserve factual default, native compressor ownership, `memory.provider: llm-brain`, `context.engine: llm-brain` as opt-in, and the six existing keys documented in the [integration guide](../../integrations/hermes/llm-brain/README.md).

**Complexity/risk:** High / medium-high. The main risks are version drift, incomparable embeddings, and declaring a winner when a provider is unavailable.

**Acceptance tests:**

- Every trace records stable/main status, exact commit/version, configuration, provider/model/dimension identity, warm/cold state, budget, availability and degraded path; see the evaluator's [run identity contract](../../docs/evaluation.md#output-and-identity).
- Measure retrieval hits, current-state correctness, stale/visibility leakage, provenance independence, repair isolation, capsule invalidation, latency, context bytes/tokens and write cost separately from answer-runner accuracy.
- No unavailable system receives a winner label; without an answer runner, answer accuracy remains `unmeasured`.
- Existing [lifecycle](../../tests/lifecycle-eval-self-check.sh), [evaluation](../../tests/eval-self-check.sh), [retrieval planner](../../tests/retrieval-planner-self-check.sh), and [Hermes compatibility](../../tests/compatibility-self-check.sh) checks remain valid.

#### P0.2 Truthful partial/degraded retrieval, bounded spill and failure envelopes

Standardise the existing LLM-Brain `degraded`, warning and incomplete fields into a stable bridge result envelope, and add bounded spill/truncation receipts where a result exceeds the configured context budget. Use the Hermes [oversized-prefetch change](https://github.com/NousResearch/hermes-agent/commit/d932fa5), OpenClaw [partial-result visibility recheck](https://github.com/openclaw/openclaw/commit/4681f8d), and OpenClaw [JSON failure-envelope change](https://github.com/openclaw/openclaw/commit/d1e5a1) as design inputs, not code to copy.

**Value and fit:** High. This strengthens fail-open behaviour without turning incomplete context into false absence. Visibility filtering, source hashes, authority and canonical OKF remain upstream of rendering; existing [evidence bundles](../../references/architecture.md#state-resolution-and-evidence-independence) remain derived.

**Hermes compatibility:** The provider and ContextEngine must continue to receive bounded Markdown or a parseable unavailable/partial response; native compression, token accounting, message order, tool pairing and capture must remain untouched. See [Hermes bridge behaviour](../../integrations/hermes/llm-brain/README.md#host-neutral-bridge).

**Complexity/risk:** Medium / high. Oversized or restricted content must never be spilled into an uncontrolled path or exposed through warnings, counts, titles or hashes.

**Acceptance tests:**

- Every bridge response is valid JSON with explicit `complete`, `partial`, `degraded` or `failed` state, warning/action metadata, budget/truncation accounting and no hidden-path leakage.
- Oversized content is bounded by bytes/tokens; any spill is local, hash-bound, redaction-safe and never canonical.
- A visibility change between selection and render rechecks access and removes the record from output/counts.
- Provider timeout/malformed output preserves durable capture and returns a truthful degraded state; add regressions beside [compatibility](../../tests/compatibility-self-check.sh) and [retrieval planner](../../tests/retrieval-planner-self-check.sh).

#### P0.3 Duplicate-hook/registration ledger and single-injector proof

Add a diagnostics and regression layer around the existing Hermes provider/context registration. The target behaviour is informed by Hermes main's [single-owner hook fix](https://github.com/NousResearch/hermes-agent/commit/684a2cf) and [fallback ledger fix](https://github.com/NousResearch/hermes-agent/commit/5bd439d), while the LLM-Brain provider contract remains unchanged.

**Value and fit:** High for runtime correctness. It protects authority and capture lineage from duplicate registration without changing canonical memory.

**Hermes compatibility:** Loading/reloading a plug-in must leave at most one provider capture path and one recall injector; selecting the ContextEngine suppresses provider injection while capture continues, as documented in the [Hermes integration guide](../../integrations/hermes/llm-brain/README.md#components).

**Complexity/risk:** Medium / medium. The risk is silently dropping a legitimate registration or changing host lifecycle ordering.

**Acceptance tests:** Register twice, reload, switch profiles, and select each context-engine mode; assert exactly one capture, one recall injection, no duplicate tool/hook, stable owner diagnostics, preserved six-key config, and no canonical write from registration alone.

#### P0.4 Atomic derived-index rebuilds and watcher/index health

Keep LLM-Brain's existing staged/atomic derived-index approach, then expose explicit stale, missing, watcher-exhausted and rebuild-in-progress health. OpenClaw's [atomic rebuild/async cleanup](https://github.com/openclaw/openclaw/commit/2a48854) and [watcher exhaustion diagnostics](https://github.com/openclaw/openclaw/commit/563b155) are operational references; they do not replace LLM-Brain's Markdown custody model.

**Value and fit:** High for predictable retrieval. Indexes remain rebuildable and derived; failed rebuilds must leave the last good index and never mutate canonical OKF.

**Complexity/risk:** Medium / medium-high, mainly around concurrent readers, stale manifests and storage growth.

**Acceptance tests:** Readers see either the previous complete index or the new complete index; a failed build leaves the previous index intact; model/dimension/view changes force an explicit rebuild; health output identifies stale/missing/vector-degraded/watcher-exhausted states; source custody and canonical hashes are unchanged. Extend [index status](../../bin/llm-brain) and the [evaluation checks](../../tests/eval-self-check.sh).

### P1 — controlled interoperability and evidence presentation

#### P1.1 Custody-aware replication manifest

Extend the existing canonical-only bundle into an optional manifest covering canonical references, source-custody hashes, episode lineage, review/tombstone state, project scope and principal/audience scope. Keep import staged, deduplicated, conflict-visible and reviewable.

**Acceptance tests:** Round-trip preserves hashes and retractions; missing/changed bytes are reported; restricted material is excluded from unauthorised export; dry-run and conflict paths leave canonical OKF unchanged; external observations cannot auto-promote; no reciprocal write loop. The current [CLI export/import path](../../bin/llm-brain) and [canonical-layer rules](../../references/architecture.md#data-layers) are the compatibility baseline.

#### P1.2 Staged, read-only OpenClaw adapter

Add an explicit adapter only for a pinned OpenClaw format/version. Use the official [memory provenance](https://docs.openclaw.ai/concepts/memory-provenance), [memory search](https://docs.openclaw.ai/concepts/memory-search), and [memory-wiki](https://docs.openclaw.ai/plugins/memory-wiki) contracts as input. Imported material remains external observation until LLM-Brain review/commitment policy accepts it.

**Acceptance tests:** Preserve source path/type/timestamp/resource metadata and add new custody; filter private scope before traversal/counting; expose version drift diagnostically; default to read-only/staged operation; prohibit automatic promotion and reciprocal writes; retain original provenance and retractions.

#### P1.3 Evidence disclosure improvements

Build on existing `intent=evidence`, lifecycle bundles and summary/detail projections rather than introducing a second evidence model. Add explicit summary → cited evidence → bounded detail selection only where benchmark or operator feedback identifies a gap; see [existing evidence semantics](../../references/architecture.md#state-resolution-and-evidence-independence).

**Acceptance tests:** Every emitted claim has a source reference or unresolved label; budgets and truncation are explicit; hidden/unresolved relationships stay warning-first; old bridge fields remain parseable; retraction invalidates dependent projections; [reconsolidation](../../tests/reconsolidation-self-check.sh) and state/commitment tests remain valid.

### P2 — optional presentation and modality work

#### P2.1 Read-only inspection view

Generate a disposable HTML/Obsidian-compatible view over canonical Markdown and derived indexes, showing lineage, state chains, conflicts, capsule closure, privacy scope and rebuild health. It must remain a view, not an authority layer. This extends the existing [derived-layer architecture](../../references/architecture.md#data-layers).

**Acceptance tests:** Rebuild from source; show warnings and provenance; filter restricted material before rendering; delete the view without changing canonical hashes; no UI edit path bypasses review/custody.

#### P2.2 Modality-aware accounting, only with a concrete use case

If an approved image/audio/document use case appears, add content-hash references and bounded transcript/description projections, informed by Hermes' [image token calibration commit](https://github.com/NousResearch/hermes-agent/commit/be58c276). Keep binary custody outside canonical Markdown and keep unsupported modalities explicitly degraded.

**Acceptance tests:** Media and text hashes round-trip; visibility and retraction apply to both; token/byte estimates are labelled as estimates; no binary, embedding or model output becomes canonical authority; Hermes bridge remains bounded and fail-open.

## Explicit skip list

- Replacing canonical OKF/Markdown with a graph database, daemon, hosted memory service, or UI. Preserve the [filesystem-first architecture](../../references/architecture.md).
- Adding a mandatory learned cross-encoder, entity graph, multimodal model, embedding service, or new runtime dependency before P0.1 measures a real gap. Existing optional vector/hybrid support is sufficient as a baseline; see [retrieval controls](../../README.md#retrieval-and-memory-control).
- Treating vendor/academic-reported scores or main-branch commits as stable-release or answer-quality proof. Keep stable and main evidence separate, as in the [prior comparison](2026-09-06-hermes-openclaw-memory-comparison.md).
- Auto-promoting OpenClaw/Hermes/provider observations, summaries, profiles or “dreaming” output into canonical OKF. Preserve [commitment and promotion policy](../../references/architecture.md#commitment-decisions-and-procedure-capsules).
- Reciprocal OpenClaw/Hermes write synchronisation before staged import/export, custody, visibility and conflict tests pass.
- Fleet-wide activation of the optional Hermes ContextEngine before separate live provider, capture, injection and native-compressor proof. The [Hermes integration](../../integrations/hermes/llm-brain/README.md) keeps it opt-in.
- Full multimodal storage or transcription without a concrete authorised use case and custody design.
- Implicit deletion/retention of source custody to control index growth; measure and report storage first.

## Limitations and unresolved citation gaps

- The negative academic result is cut-off-bounded and was not a proof of absence. The supplied [`agent-memory-atlas/membench@1857406`](https://github.com/agent-memory-atlas/membench/commit/1857406) URL did not resolve publicly in this pass; retain it as an unresolved lane citation until the exact repository/commit URL is supplied.
- Hermes `v0.21.0` and OpenClaw `2026.9.2` stable status are completed-lane evidence. The official Hermes documentation and OpenClaw [release page](https://docs.openclaw.ai/releases/2026.9.2) are linked, but this update does not independently re-run either product's full release acceptance suite.
- Main-branch commits are implementation signals only. They are not automatically compatible with the stable releases or with the LLM-Brain six-key provider contract.
- LLM-Brain comparative answer quality remains unmeasured without a common answer runner. The repository evaluator measures lifecycle/retrieval properties and keeps evaluation output derived; see the [evaluation guide](../../docs/evaluation.md).
- This update is documentation-only. No product source, live provider, release artefact, commit, push, or vault capture was performed.
