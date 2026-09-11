# LLM-Brain research update

**Date:** 2026-09-09
**Scope:** recommendations for LLM-Brain itself, not a cross-system ranking.

## Executive conclusion

The strongest evidence supports better measurement, provenance, deterministic state handling, and failure recovery—not a new memory substrate. LLM-Brain should keep filesystem-first, inspectable Markdown/OKF v0.2 canonical truth; schema 3; SHA-256 custody; review/promotion boundaries; visibility; deterministic state resolution; Hermes compatibility; and no mandatory dependency, daemon, database, model-training, or automatic-execution requirement.

The adoptable core is an evidence-bearing lifecycle around derived indexes: evaluate retrieval/update/temporal consistency/forgetting, emit auditable retrieval receipts, make claim/evidence attribution atomic, expose typed degradation, publish derived indexes atomically, and provide provenance-aware forget previews/tombstones. Optional read-only views and explicitly opt-in Hermes custody/diagnostics can improve operations without becoming authority. These are constrained recommendations and inferences, not claims of superiority.

## Evidence ledger

### Academic and benchmark evidence

| Evidence | Finding relevant to LLM-Brain | Design implication | Confidence |
|---|---|---|---|
| [MemBench](https://aclanthology.org/2025.findings-acl.989/) (2025) | Memory quality has factual/reflective effectiveness, efficiency, and capacity dimensions. | Measure more than answer accuracy: cost, capacity, and reflection. | High |
| [MemoryAgentBench](https://arxiv.org/abs/2507.05257) (2025) | Retrieval, test-time learning, long-range understanding, and selective forgetting fail differently. | Use a matrix with separate lifecycle metrics and forgetting cases. | High |
| [THEANINE](https://aclanthology.org/2025.naacl-long.435/) (2025) | Timelines and causal links matter to memory use. | Preserve dates, temporal validity, and typed relationships in evidence. | Medium |
| [Reflective Memory Management](https://aclanthology.org/2025.acl-long.413/) (2025) | Multi-granularity, evidence-cited summaries improved LongMemEval by more than 10% in the reported setting. | Prefer evidence-cited derived summaries with source links and masking/recovery tests. | Medium |
| [How Memory Management Impacts LLM Agents](https://aclanthology.org/2026.acl-long.27.pdf) (ACL 2026) | Experience-following can propagate errors; future outcomes can act as labels. | Track update provenance and test obsolete-memory reliance; do not treat future labels as authority. | Medium |
| [Mem2ActBench](https://aclanthology.org/2026.acl-long.370/) (ACL 2026) | Proactive memory-to-action use needs acceptance evaluation. | Keep automatic execution out of core; future action integration requires explicit acceptance tests. | Medium |
| [Evaluating Evidence Attribution](https://aclanthology.org/2025.naacl-long.282/) and [HALoGEN](https://aclanthology.org/2025.acl-long.71/) (2025) | Attribution and hallucination need targeted evaluation, not assumed citations. | Add citation masking/recovery and contradiction fixtures. | High |
| [LongMemEval](https://arxiv.org/abs/2410.10813), [EvoMemBench](https://arxiv.org/abs/2605.18421), [HalluLens](https://aclanthology.org/2025.acl-long.1176/) | Longitudinal, evolving, and hallucination/error cases expose stale reliance. | Record run identity and test stale-result leakage over updates. | Medium |
| [WikiMem/right-to-be-forgotten](https://arxiv.org/abs/2507.11128) | Forgetting requires accounting for residual traces, not only deleting one record. | Preview tombstones and report residual coverage. | Medium |
| [AgeMem](https://aclanthology.org/2026.acl-long.981/) (ACL 2026) | RL memory controllers are a research direction. | Defer: no evidence justifies making RL a core dependency. | High |

### Hermes: stable versus main

Stable is [v0.21.1 / v2026.9.7, commit 2237be3](https://github.com/NousResearch/hermes-agent/releases). Its official [memory-provider API](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/memory-provider-plugin.md) and [implementation](https://github.com/NousResearch/hermes-agent/blob/main/agent/memory_provider.py) provide a single selected provider, local/config-only availability, non-blocking `sync_turn`, prefetch hooks, and session/compression hooks. Main signals include oversized prefetch spill/head-tail preview ([d932fa5](https://github.com/NousResearch/hermes-agent/commit/d932fa5)), duplicate hook ownership ([684a2cf](https://github.com/NousResearch/hermes-agent/commit/684a2cf), [5bd439d](https://github.com/NousResearch/hermes-agent/commit/5bd439d)), checkpoint API v2 in the provider contract, and the [context-engine contract](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/context-engine-plugin.md).

**Implication:** adopt bounded derived spill, typed failure envelopes, optional checkpoint-required custody mode, and token/budget diagnostics. Reject external authority, automatic context-engine adoption, synchronous capture, and `queue_prefetch` until measured.

### OpenClaw: stable versus main

Stable is [v2026.9.3](https://github.com/openclaw/openclaw/releases/tag/v2026.9.3). Relevant documentation covers [built-in memory](https://docs.openclaw.ai/concepts/memory-builtin), [memory](https://docs.openclaw.ai/concepts/memory), [provenance](https://docs.openclaw.ai/concepts/memory-provenance), [memory wiki](https://docs.openclaw.ai/plugins/memory-wiki), [CLI](https://docs.openclaw.ai/cli/memory), and [v2026.9.2 release recovery](https://docs.openclaw.ai/releases/2026.9.2). Main signal [338a53f](https://github.com/openclaw/openclaw/commits/main/) reinforces explicit provider/config state. The stable v2026.9.1 lane demonstrates reset/replacement cache, failed-rebuild preservation, retry, and lock recovery patterns.

**Implication:** use typed retrieval outcomes, explicit provider/store selectors, atomic derived-index publication/health, preview-first forget/tombstones with residual coverage, and a read-only compiled claims/evidence view. Do not replace Markdown/OKF, adopt wiki authority, claim global erasure, add a graph engine, or use learned reranking without benchmarks.

## Prioritised adoptable backlog

| Priority | Recommendation | Minimal implementation and acceptance tests | Complexity / risk / dependencies | Confidence |
|---|---|---|---|---|
| P0 | Evaluation matrix | Add deterministic fixtures for retrieval, update, temporal consistency, forgetting, and obsolete-memory reliance. Acceptance: repeatable report, seeded cases, no canonical writes. | M / low / existing test harness | High |
| P0 | Atomic claim/evidence attribution | Store claim-to-source references and citation status in derived output; add masking/recovery and contradiction fixtures. Acceptance: hidden evidence cannot appear; missing source abstains. | M / medium / schema-compatible derived layer | High |
| P0 | JSONL retrieval receipts | Record query, candidates, ranking, selected evidence, visibility, abstention, model/index identity, and run hash. Acceptance: replay identifies exact inputs and selection; receipts are non-canonical. | S–M / low / stdlib JSONL | High |
| P0 | Provenance-aware forget | Implement preview then tombstone, with source hashes, affected derived records, coverage, and residuals. Acceptance: no deletion before confirmation; hidden/tombstoned material is excluded and residuals are explicit. | M / high / custody and visibility rules | High |
| P1 | Typed degraded retrieval | Define `degraded`, `partial`, and `unavailable` envelopes with warnings and abstention. Acceptance: callers never confuse empty with unavailable; current truth remains fail-safe. | S / low / existing CLI contracts | High |
| P1 | Atomic derived-index health/rebuild | Build into a staging path, validate, hash, then publish atomically; preserve last-known-good on failure. Acceptance: interrupted/failed rebuild leaves prior index usable and health reports state. | M / medium / filesystem atomic rename | High |
| P1 | Read-only compiled OKF claims/evidence view | Generate linted claims, citations, dates, visibility, and contradictions without changing OKF. Acceptance: source paths/hashes remain visible; lint output is explicitly derived. | M / medium / no new dependency | Medium |
| P2 | Hermes custody and diagnostics | Opt-in checkpoint-required custody mode plus token/budget counters; retain fail-open warnings by default. Acceptance: opt-in blocks uncommitted turn capture, default compatibility remains unchanged. | S–M / medium / Hermes API versioning | Medium |

## Explicit defer/reject list

Defer autonomous RL memory controllers; graph/database replacement; learned rerankers; multimodal storage without a concrete use case; reciprocal OpenClaw synchronisation; and any model dependency. Reject external provider authority, wiki authority, automatic Hermes context-engine adoption, synchronous capture, unmeasured prefetch queues, global erasure claims, and automatic execution. These would weaken inspectability, custody, determinism, compatibility, or the no-mandatory-runtime boundary.

## Phased implementation plan

1. **Baseline:** freeze fixtures and evaluation matrix; document metric definitions and run hashes.
2. **Evidence:** add atomic attribution, JSONL receipts, typed outcomes, and abstention semantics.
3. **Recovery:** add forget preview/tombstones and atomic derived-index staging/publication with last-known-good recovery.
4. **Operator views:** add the read-only compiled claims/evidence view and contradiction lint.
5. **Optional integration:** add Hermes checkpoint custody and token/budget diagnostics only after compatibility tests against stable and main contracts.
6. **Reassess:** consider any deferred feature only with a bounded benchmark, explicit authority, failure-recovery proof, and a demonstrated benefit over the filesystem-first design.

## Limitations and no-go claims

The cited papers include preprints and results measured in particular tasks, models, and datasets; reported gains do not transfer automatically. Hermes and OpenClaw main branches are moving targets; stable/main observations are snapshots dated 2026-09-09. Comparable systems—[Hindsight](https://arxiv.org/abs/2512.12818), [Letta visibility blocks](https://docs.letta.com/tutorials/attaching-detaching-blocks/), [Graphiti](https://help.getzep.com/graphiti/getting-started/welcome), [OpenViking](https://github.com/volcengine/OpenViking), [VikingMem](https://arxiv.org/abs/2605.29640), [Honcho](https://github.com/plastic-labs/honcho), and [LoCoMo audit](https://github.com/dial481/locomo-audit/blob/main/methodology/reproducibility.md)—are inspiration/evidence only, not authority.

This report does not claim improved model intelligence, universal forgetting, cross-system superiority, production readiness, or permission to modify the live vault. It recommends derived, inspectable mechanisms whose acceptance must be proven locally.

## Sources

All links above were consulted or supplied for this update and are dated 2025–2026 as indicated in the ledger; repository release/commit links were checked against the stable/main split on 2026-09-09. Additional comparison sources are linked in the limitations section.
