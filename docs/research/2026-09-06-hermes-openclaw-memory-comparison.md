# LLM-Brain, Hermes and OpenClaw memory comparison

**Date:** 2026-09-06

**Subject:** the local LLM-Brain `0.6.2` candidate compared with Hermes native memory and providers, and OpenClaw native and third-party memory options.
**Decision boundary:** preserve LLM-Brain's filesystem-first, canonical OKF design. This report identifies compatible improvements; it does not recommend replacing the core with a daemon, graph database or hosted memory service.

## Executive assessment

The `0.6.2` workspace candidate is strongest where memory must remain inspectable, custody-backed and safe to use in an evolving project: canonical OKF Markdown, SHA-256 source custody, explicit review boundaries, principal/audience filtering, deterministic current-state outcomes, independent-source accounting, commitment decisions and hash-bound procedure capsules. Its Hermes adapter also preserves the existing provider/context-engine contract and native compression path. These are capability claims grounded in the candidate source and documentation, not a head-to-head quality benchmark; see the [candidate architecture](../../references/architecture.md) and [Hermes integration contract](../../integrations/hermes/llm-brain/README.md).

LLM-Brain is behind the surrounding ecosystem in semantic recall and operational convenience. OpenClaw's native memory has a broader embedding/provider surface, hybrid vector/keyword retrieval and configurable recency/importance/MMR controls; its memory-wiki adds a structured, inspectable knowledge layer and dashboards. OpenViking adds hierarchical progressive loading and retrieval traces. Hindsight and Mem0 provide richer graph/entity extraction and learned reranking. Hermes provides a very clean native lifecycle seam, built-in profile memory and Journey tooling. These systems are not interchangeable guarantees: their operational and semantic advantages should be measured against LLM-Brain's custody and policy boundaries, not assumed to prove better answer quality.

The practical goal is therefore: **add optional, rebuildable semantic and presentation layers around canonical OKF, while keeping deterministic custody, visibility, state resolution and capsule validation authoritative.**

## Evidence discipline and scope

- **Candidate evidence** means behaviour documented in this workspace's [README](../../README.md), [architecture](../../references/architecture.md), [release notes](../releases/v0.6.2.md) and [Hermes integration guide](../../integrations/hermes/llm-brain/README.md). `VERSION` currently reads `0.6.2`; this is an uncommitted candidate, not a published release.
- **Primary-source evidence** is linked inline to official Hermes, OpenClaw and project documentation. Pages were reviewed on 2026-09-06. Provider feature descriptions are capabilities documented by their maintainers, not independent measurements.
- **Inference** is labelled as assessment. “Ahead” and “behind” below mean better or worse fit for the stated property, not overall model-answer quality.
- There is no common, controlled LLM-Brain/Hermes/OpenClaw benchmark in this repository. The candidate's lifecycle evaluator measures state, provenance, repair, poisoning and capsule behaviour; without an answer runner, model-answer accuracy is explicitly unmeasured. No numerical vendor benchmark is treated as proof here.
- **Version pinning matters.** The OpenClaw releases page currently lists stable `2026.9.2` (2026-09-05), while local installations may differ; the [release list](https://github.com/openclaw/openclaw/releases) is the authority for a benchmark target. The Hermes evidence uses [source commit `245e48008fa814b3251f50755eb656bd9fb86cb1`](https://github.com/NousResearch/hermes-agent/tree/245e48008fa814b3251f50755eb656bd9fb86cb1), which is newer than the `v0.21.0` tag; source-contract results must not be presented as tag-release results.

## Capability baseline: the LLM-Brain candidate

The candidate stores canonical semantic memory as OKF v0.2 Markdown, with episodes, review, audit and content-addressed source custody kept as separate supporting layers. Current-state resolution is opt-in and returns explicit states such as `current`, `unknown-validity`, `unresolved-conflict`, `unresolved-dependency`, `unresolved-inaccessible`, `invalid-cycle` and `historical`. The candidate does not invent validity dates or present unresolved material as current truth. These properties are described in [architecture.md](../../references/architecture.md#state-resolution-and-evidence-independence).

The new lifecycle controls are additive:

- commitment actions (`persist`, `use-now`, `reverify`, `ask`, `quarantine`) produce hash-bound derived decisions; `shadow` remains the default;
- procedure capsules bind an exact procedure hash, target, task, principal, bindings, dependency closure, evidence and verification requirements; validation is read-only and capsule-enabled runs recheck under the project lease;
- evidence intent produces bounded, visibility-filtered lifecycle bundles with warnings and `incomplete` markers;
- selected records are grouped by provenance roots so correlated copies do not count as independent sources.

The retrieval path is not purely lexical: it supports optional vector cosine/RRF, explicit graph expansion and a deterministic Python heuristic rerank. The accurate limitation is narrower: the candidate has no evidenced learned cross-encoder/LLM reranker, adaptive entity-resolution system or temporal-graph ranker. It also has no mandatory embedding service, database or daemon. See the retrieval description in [README.md](../../README.md#retrieval-and-memory-control) and [architecture.md](../../references/architecture.md#trust-lifecycle-and-retrieval).

## Comparison matrix

| Option | Evidence-backed strengths | Relative LLM-Brain trade-off |
| --- | --- | --- |
| **Hermes built-in memory** | Bounded `MEMORY.md`/`USER.md` profile memory, session-start injection, local SQLite FTS5 search and Journey/TUI/desktop editing are documented in the [memory guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/). | Easier host-native editing and session UX. The reviewed native-memory documentation does not describe LLM-Brain's exact OKF state/dependency resolver or target-bound capsule closure; that is a scope comparison, not proof that Hermes cannot add such controls. |
| **Hermes external provider seam** | Hermes exposes one active external provider slot and a lifecycle for inject, prefetch, sync, extraction, mirror writes and tools; the [provider guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers/) and [plugin guide](https://hermes-agent.nousresearch.com/docs/developer-guide/memory-provider-plugin/) define the contract. | Hermes owns the compressor/checkpoint and host lifecycle cleanly. LLM-Brain's adapter fits that seam, but remains one provider among several rather than a replacement for host-native UX. |
| **OpenClaw `memory-core`** | Local Markdown memory with hybrid vector+keyword search, configurable embedding providers, recency/importance/MMR, embedding cache/batching and stale/warning metadata are documented in [memory concepts](https://docs.openclaw.ai/concepts/memory) and [memory configuration](https://docs.openclaw.ai/reference/memory-config). | Ahead on embedding/provider breadth and semantic recall controls. LLM-Brain is more explicit about canonical OKF boundaries, exact lifecycle states, dependency closure and procedure capsules in the reviewed implementation. OpenClaw also documents deterministic policy, provenance and trust controls; LLM-Brain must not claim those categories are uniquely its own. |
| **OpenClaw `memory-wiki`** | A companion layer with structured claims, status/confidence/evidence, contradiction/freshness/provenance/privacy dashboards, isolated/bridge modes and OKF import is documented in the [memory-wiki guide](https://docs.openclaw.ai/plugins/memory-wiki). | Ahead on dashboards, browsing and administrative visibility. LLM-Brain's candidate evidence is stronger for SHA-256 source custody, exact validity/dependency outcomes, principal/audience filtering and lock-time capsule validation; the OpenClaw documentation does not establish equivalent guarantees, but this is not a claim that it lacks provenance. |
| **OpenClaw LanceDB plugin** | Local vector auto-recall/capture, per-agent ownership, provider/model/index identity, stale-lock repair and explicit rebuild/doctor operations are documented in the [LanceDB plugin guide](https://docs.openclaw.ai/plugins/memory-lancedb) and [memory CLI guide](https://docs.openclaw.ai/cli/memory). | Ahead on operational index management, embedding choices and multimodal/provider ecosystem. LLM-Brain is ahead for canonical source-first lifecycle semantics and target-bound procedures; both require strict handling of private-agent scope and rebuild identity. |
| **OpenViking** | Filesystem-paradigm context storage, hierarchical L0/L1/L2 progressive loading, traces and session extraction/commit are documented at [OpenViking](https://docs.openviking.ai/) and its [OpenClaw integration](https://docs.openviking.ai/en/agent-integrations/03-openclaw). | Ahead on progressive context and retrieval observability. Its OpenClaw integration requires a compatible Node/OpenClaw version and running OpenViking server, so LLM-Brain is simpler to deploy and more self-contained. The two systems' answer quality is unmeasured here. |
| **Hindsight** | Entity/relationship/time-aware memory, semantic+BM25+graph retrieval and reranking are described in the [project README](https://github.com/vectorize-io/hindsight/blob/main/README.md). | Ahead on associative and temporal semantic recall. LLM-Brain is lighter and keeps raw Markdown custody and deterministic closure in the local canonical path; the project/service/LLM/DB trade-offs must be measured, not assumed. |
| **Mem0** | Extraction, entity linking, hybrid vector/graph retrieval, reranking and consolidation are described in the [OpenClaw integration](https://docs.mem0.ai/integrations/openclaw) and the [Mem0 paper](https://arxiv.org/abs/2504.19413). Any numerical results are vendor/academic-reported until reproduced under the common benchmark below. | Ahead on automated consolidation and entity-oriented recall. LLM-Brain is ahead on explicit custody and no mandatory model/embedding pipeline; automatic extraction must not be allowed to gain canonical authority without the existing review and commitment gates. |
| **Honcho** | Peer/user models, cross-session context and dialectic reasoning are described in the [overview](https://honcho.dev/docs/v2/documentation/introduction/overview), which also warns that poor prompts can conflate self and user. | Ahead on user/agent modelling. LLM-Brain's principal/audience fields and explicit source custody provide a clearer safety boundary for project facts; this does not replace a user-model feature. |
| **Other Hermes providers** | Hermes' official provider list includes Honcho, OpenViking, Mem0, Hindsight, Holographic, RetainDB, ByteRover and Supermemory ([provider guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers/)). | They expand hosted, hybrid, graph or profile-oriented recall choices. Comparative details should be checked against the exact installed version before selecting one; availability alone is not evidence of superior integrity or answer quality. |

## Where LLM-Brain is ahead

These are narrow, evidence-backed advantages for a filesystem-first canonical memory system:

1. **Canonical custody is explicit.** Source bytes, hashes, episodes, review and canonical OKF are separate and inspectable. Derived packs, bundles, indexes, capsules and provider observations cannot silently become canonical truth.
2. **Evolving state fails closed.** Current-state retrieval is opt-in, distinguishes unknown validity from conflict or inaccessible dependency, follows bounded exact relations and puts unresolved material in warnings. This is a better fit for release, configuration, policy and other stateful project facts than a bare semantic similarity hit.
3. **Procedures are target-bound.** A capsule records the exact procedure/dependency/evidence hashes and rechecks them under the project lease. A changed or hidden dependency makes the capsule stale or blocked; Hermes never executes capsules automatically.
4. **Evidence correlation is visible.** Root-source grouping and independent-source counts expose when many records are copies of one source. This is an integrity signal, not a claim that other systems cannot implement one.
5. **Low operational footprint.** The candidate uses Markdown, standard-library/runtime interfaces and existing Hermes hooks without a required database, daemon, network service or embedding provider. OpenViking, Hindsight and hosted/vector options can offer more capability at the cost of services, indexes or model/provider dependencies.
6. **Hermes compatibility is deliberately additive.** The `llm-brain` provider name, six configuration keys, single-injector behaviour, native compressor inheritance and fail-open boundaries remain unchanged; current-state and evidence modes require explicit selection. See the [integration guide](../../integrations/hermes/llm-brain/README.md).

## Where LLM-Brain is behind

1. **Semantic recall depth.** The candidate has optional vector/RRF and deterministic heuristic reranking, but no demonstrated learned cross-encoder, entity-linking pipeline, graph-aware semantic reranker or multimodal embedding path. Hindsight, Mem0, OpenClaw memory-core/LanceDB and some Hermes providers offer more of these building blocks.
2. **Progressive context and UX.** OpenViking's hierarchical loading/traces, OpenClaw memory-wiki dashboards and Hermes Journey are more convenient for browsing, editing, inspection and budget-aware context exploration. LLM-Brain's derived packs are inspectable Markdown but do not yet provide an equivalent interactive view.
3. **Automatic profile and consolidation features.** OpenClaw dreaming, Mem0 consolidation, Hindsight experience/entity modelling and Honcho peer modelling provide richer derived views. LLM-Brain deliberately keeps derived observations non-canonical and conservative; it therefore offers less automation today.
4. **Ecosystem and multimodality.** OpenClaw exposes more embedding providers and optional image/audio paths; third-party systems offer hosted or multi-agent synchronisation. LLM-Brain has no equivalent general-purpose replication ledger or multimodal projection.
5. **Comparative proof.** The candidate readiness evaluator proves lifecycle properties but not that it retrieves more useful answers or costs fewer tokens than Hermes/OpenClaw/provider alternatives. A common benchmark is the highest-value missing evidence.

## Implementation-goal backlog

All items below are optional derived layers around canonical OKF. None should make a vector index, summary, graph, hosted service, model output or UI the only source of truth.

### P0 — establish comparable quality and improve retrieval safely

**P0.1 Common synthetic benchmark.** Build a repository-only fixture compiler that projects the same facts, conflicts, temporal changes, visibility scopes, poisoning attempts and procedures into LLM-Brain, Hermes native memory, OpenClaw memory-core/memory-wiki/LanceDB and any selected locally runnable provider. Record exact versions, configuration, embedding/model identity, warm/cold state and availability. Measure recall/precision at `k`, current-state accuracy, stale leakage, visibility leakage, provenance-root correctness, capsule stale detection, repair isolation, p50/p95 latency, context bytes/tokens, writes and index/build cost. Score answers outside the runner and label vendor-reported numbers separately.

**Acceptance:** no system receives a “winner” label when a capability is unavailable or a provider failed; all traces retain source/version/config identity; LLM-Brain factual defaults and current-state warnings remain unchanged; model-answer accuracy is explicitly `unmeasured` when no answer runner is supplied.

**P0.2 Optional semantic ranker.** Add a rebuildable derived ranker/embedding sidecar with deterministic lexical fallback, exact-identifier bypass, index identity and explicit degraded mode. Prefer an installed local runtime; do not add a mandatory dependency. Start with entity aliases and temporal/state-aware ranking before considering a learned cross-encoder.

**Acceptance:** canonical Markdown is untouched; changing model/provider/dimensions forces a declared rebuild; restricted records never enter visible ranking; current-state and evidence resolution happen before ranking can suppress warnings; benchmark reports whether semantic ranking improves recall without increasing stale or visibility leakage.

**P0.3 Progressive evidence disclosure.** Add summary → cited evidence → full bounded excerpt as a derived context-pack projection, retaining the existing warning-first and source-hash rules. Use explicit intent/budget controls; never silently expand hidden or unresolved records.

**Acceptance:** every emitted claim has a visible source reference or is labelled unresolved; output stays within budget; omitted detail is recorded as truncation rather than presented as absence; old bridge consumers continue to parse the existing fields.

### P1 — derived intelligence and interoperability

**P1.1 Reviewed observations and profiles.** Add optional non-canonical observations/profile/mental-model records with root hashes, freshness, conflict, independence and principal/audience metadata. Route every promotion through existing commitment/review gates; derived summaries never uplift authority.

**Acceptance:** retracting a root invalidates dependent projections; source hashes and visibility survive rebuild; a derived observation cannot outrank or replace a canonical source; poisoning and repair tests cover the full chain.

**P1.2 Content-addressed export/import and replication ledger.** Define a portable manifest of source hashes, canonical refs, episode lineage, project/principal scope and tombstones. Import is staged, deduplicated and reviewable; conflicts stay explicit. This supplies multi-agent sync without making a server mandatory.

**Acceptance:** round-trip export/import preserves hashes and retractions; missing or changed bytes are reported; restricted material is excluded from an unauthorised export; imports cannot auto-promote external observations.

**P1.3 OpenClaw interoperability adapter.** Provide an explicit, read-only or staged OKF bridge for OpenClaw Markdown/memory-wiki artifacts, with declared public/private scope and import provenance. Keep LLM-Brain canonical storage authoritative and make the adapter optional.

**Acceptance:** imported claims retain original path/type/timestamp/resource metadata and new custody; bridge mode cannot expose private material; no automatic reciprocal write loop; import/version drift appears in diagnostics.

### P2 — presentation and multimodal projections

**P2.1 Read-only inspection UI.** Produce a static HTML/Obsidian-compatible view over canonical records and derived indexes: source lineage, state chain, conflicts, dependency closure, capsule status, privacy scope and rebuild health. Keep it rebuildable from Markdown and safe to delete.

**P2.2 Multimodal custody projections.** Add optional image/audio/document references with content hashes, bounded text/transcript projections and explicit modality metadata. Keep binary custody outside canonical Markdown where appropriate; the projection must be retractable and visibility-filtered.

**Acceptance:** no binary or embedding becomes canonical authority by itself; text and media hashes round-trip; unsupported modality degrades clearly; the Hermes bridge remains bounded and fail-open.

## Cross-cutting acceptance criteria

- `factual` remains the default; current-state, evidence and richer projections are explicit.
- Canonical OKF Markdown, source custody, review, visibility, supersession, retraction and dependency semantics remain authoritative.
- New indexes, graphs, summaries and profiles are derived, rebuildable and safe to remove.
- No mandatory daemon, hosted service, graph database, model training or runtime dependency is added to the core.
- Hermes keeps the `llm-brain` selector, six configuration keys, provider/context-engine single-injector contract, native compressor behaviour and fail-open boundaries.
- OpenClaw import/export is explicit about scope and provenance; it does not create an automatic promotion loop.
- Every benchmark result records source versions, configuration, model/provider identity, warm/cold state, budgets and unavailable/degraded paths.
- No restricted path, title, hash, count or excerpt leaks through retrieval, evidence bundles, exports, UI or benchmark traces.
- Documentation states whether a claim is observed, inferred or vendor-reported; no unsupported performance or uniqueness claim is published.

## Dependencies and risks

- **Version drift:** Hermes and OpenClaw docs and source can disagree across releases. Pin the target commit/version in each benchmark run; the reviewed OpenClaw dreaming defaults already show documentation drift between current docs and older repository docs.
- **Embedding/index drift:** provider, model, dimensions, tokenizer and chunking changes invalidate comparable indexes. Require an index identity and explicit rebuild, never silent fallback.
- **Privacy and authority:** richer graph/entity/profile extraction increases the chance of principal mixing or derived authority uplift. Keep visibility filtering before traversal/counting and retain human/review gates.
- **Operational cost:** services such as OpenViking, Hindsight, Mem0 or hosted providers may improve recall while adding daemons, network failure, credentials, model costs and recovery paths. Keep them optional.
- **Benchmark validity:** answer quality depends on the model, prompt, budget and runner. Report retrieval and lifecycle metrics separately from model accuracy; vendor-reported benchmarks are context, not acceptance evidence.
- **Storage growth:** source custody, projections, embeddings and replication manifests can grow faster than canonical Markdown. Add bounded retention/doctor reporting only after measuring real fixtures; do not delete custody implicitly.

## Sources

Primary sources used for the comparison:

- Hermes [native memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/), [memory providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers/), [provider plugin API](https://hermes-agent.nousresearch.com/docs/developer-guide/memory-provider-plugin/) and [MemoryProvider source](https://github.com/NousResearch/hermes-agent/blob/main/agent/memory_provider.py).
- OpenClaw [memory concepts](https://docs.openclaw.ai/concepts/memory), [memory configuration](https://docs.openclaw.ai/reference/memory-config), [memory CLI](https://docs.openclaw.ai/cli/memory), [memory-wiki](https://docs.openclaw.ai/plugins/memory-wiki) and [LanceDB](https://docs.openclaw.ai/plugins/memory-lancedb).
- OpenViking [documentation](https://docs.openviking.ai/) and [OpenClaw integration](https://docs.openviking.ai/en/agent-integrations/03-openclaw).
- Hindsight [project README](https://github.com/vectorize-io/hindsight/blob/main/README.md).
- Mem0 [OpenClaw integration](https://docs.mem0.ai/integrations/openclaw) and [paper](https://arxiv.org/abs/2504.19413).
- Honcho [overview](https://honcho.dev/docs/v2/documentation/introduction/overview).
- LLM-Brain [README](../../README.md), [architecture](../../references/architecture.md), [Hermes integration](../../integrations/hermes/llm-brain/README.md) and [OKF specification](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/3fcbb9f828c2f23d109c855ee403c3a4c81f3a96/okf/SPEC.md).
