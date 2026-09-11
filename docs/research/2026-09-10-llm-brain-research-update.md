# LLM-Brain research update

**Date:** 2026-09-10
**Scope:** delta review for LLM-Brain v0.6.3; recommendations for the local filesystem-first system only.

## Executive conclusion

v0.6.3 already contains the important foundations identified in the 2026-09-09 review: schema 3 records, SHA-256 provenance/custody, visibility filtering, deterministic state resolution, evidence bundles, review/promotion separation, bounded evaluation, typed bridge JSON, and Hermes-compatible optional provider/context-engine boundaries. Repeating those as new work would be noise.

The genuinely additive work is narrower: durable JSONL retrieval receipts; a complete preview-first forget report with affected and residual coverage; an evidence-opened/citation invariant with masking and contradiction fixtures; explicit scope/visibility and metadata-isolation tests; and small deletion/provenance utility probes. Hermes checkpoint custody and budget diagnostics remain optional compatibility work, not defaults. Derived hierarchical/bitemporal discovery views and a typed provider/index vocabulary are useful only where an observed gap remains, and must stay non-authoritative.

No recommendation below changes OKF schema 3, canonical Markdown authority, SHA-256 custody, deterministic resolution, visibility, Hermes compatibility, or the no-mandatory dependency/daemon/database/model-training/automatic-execution boundary.

## What is already implemented in v0.6.3

- Lifecycle evaluation has seeded retrieval, updates, temporal validity, forgetting/repair, poisoning, visibility, provenance, unresolved state, budgets, degradation and repeatability checkpoints (`docs/evaluation.md`).
- Retrieval already exposes machine-readable strategy, degradation, resolution, budget and provenance fields; evidence mode is bounded and visibility-filtered.
- Provider results remain untrusted candidates behind validation, provenance resolution, quarantine and review/promotion policy. Provider timeout/failure paths are explicit.
- Canonical source validation, SHA-256 hashes, evidence references, state/version chains and non-canonical run outcomes are present.
- Hermes integration preserves `memory.provider: llm-brain`, optional `context.engine: llm-brain`, native compressor defaults, fail-open warnings and protected promotion policy.

These are baseline capabilities, not 10 September additions. The current gap is durable, replayable retrieval receipts and stronger negative/coverage proofs around deletion and attribution.

## Evidence ledger: stable snapshots and advisory main branches

| Source and date | Relevant evidence | Constrained implication |
|---|---|---|
| [Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions](https://arxiv.org/abs/2507.05257) (2025; introduces MemoryAgentBench) | Retrieval, updating, long-range understanding and selective forgetting fail differently. | Keep lifecycle metrics separate; do not collapse them into answer accuracy. |
| [LongMemEval](https://arxiv.org/abs/2410.10813), [LongMemEval-V2](https://github.com/xiaowu0162/LongMemEval-V2) | Longitudinal updates and metadata isolation expose stale or cross-scope recall. | Add local scope/visibility and metadata-isolation fixtures. |
| [Evaluating Evidence Attribution](https://aclanthology.org/2025.naacl-long.282/) and [HALoGEN](https://aclanthology.org/2025.acl-long.71/) | Attribution requires targeted evaluation; plausible citations are insufficient. | Require opened evidence and test masking/contradictions. |
| [THEANINE](https://aclanthology.org/2025.naacl-long.435/) | Temporal and causal structure affects memory utility. | A derived time view may aid discovery, but cannot become authority. |
| [From Recall to Forgetting](https://arxiv.org/abs/2604.20006), [VikingMem](https://arxiv.org/abs/2605.29640), [AgeMem](https://arxiv.org/abs/2601.01885), [Hindsight Memory-PRM](https://arxiv.org/abs/2608.29605), [MemPrivacy](https://arxiv.org/abs/2605.09530), [Wu et al.](https://proceedings.mlr.press/v317/wu26a.html) | Current research explores forgetting-aware evaluation, hierarchical memory, learned controllers, privacy-preserving memory and agent workflows. | Advisory evidence only; no model-training, cloud-memory or learned-controller dependency. |
| [Hermes releases](https://github.com/NousResearch/hermes-agent/releases) — stable **v0.21.1 / v2026.9.7 (7 Sep 2026)**; [provider API](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/memory-provider-plugin.md); [context-engine API](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/context-engine-plugin.md) | Stable contracts support provider/context hooks; main may move. | Test checkpoint-required custody and budgets only as opt-in compatibility features. |
| [OpenClaw releases](https://github.com/openclaw/openclaw/releases) — stable **2026.9.3 (8 Sep 2026)**; [main](https://github.com/openclaw/openclaw/commits/main/) | Official docs expose [provenance](https://docs.openclaw.ai/concepts/memory-provenance), [CLI](https://docs.openclaw.ai/cli/memory), [built-in memory](https://docs.openclaw.ai/concepts/memory-builtin), [context engine](https://docs.openclaw.ai/context-engine), and [config](https://github.com/openclaw/openclaw/blob/main/docs/reference/memory-config.md). | Borrow operational vocabulary only; OpenClaw is not an authority or substrate for LLM-Brain. |

The academic links describe particular tasks and models, not guaranteed product gains. Stable/main dates are snapshots, not a claim about current future branches.

## Genuinely additive recommendations

| Priority | Item | Value and minimal implementation | Acceptance test | Complexity / risk / confidence |
|---|---|---|---|---|
| P0 | General JSONL retrieval receipts | Persist one non-canonical receipt per recall: query hash, candidate IDs, ranking, selected evidence, visibility decision, abstention, provider/index identity, run hash and budget. Reuse existing JSON rendering and stdlib JSONL. | Replay a receipt against unchanged inputs and reproduce selection; receipt hash and source hashes resolve; no receipt enters `okf/`. | S–M / low / high |
| P0 | Complete preview-first forget coverage | Add a read-only preview that enumerates direct, derived, linked and residual traces with source hashes and coverage; confirmation writes tombstone/audit only within exact scope. | Preview causes no mutation; post-tombstone recall excludes hidden material and reports uncovered residuals; unrelated scope remains visible. | M / high custody risk / high |
| P0 | Evidence-opened citation invariant | Mark evidence as opened/verified only when the referenced source and hash resolve during rendering; add targeted masking and contradiction fixtures. | Missing/hidden/unopened evidence cannot be presented as cited support; contradiction remains unresolved and is visible in the receipt. | S–M / medium / high |
| P1 | Scope/visibility and metadata-isolation fixtures | Extend existing evaluation cases with tenant/project/principal, timestamps and distractor metadata. Keep all data synthetic and derived. | Cross-scope recall is zero; as-of and principal filters hold under repeated runs; metadata-only distractors do not leak. | S / low / high |
| P1 | Deletion/provenance utility probes | Small shell assertions around source-hash resolution, tombstone exclusion, orphaned derived references and exact-path deletion planning. | Each probe fails on an orphan, mismatched hash or out-of-scope path; no destructive action occurs during tests. | S / low / high |
| P1 | Optional Hermes checkpoint custody and budget diagnostics | Add opt-in checkpoint-required capture plus token/budget counters, retaining current fail-open defaults and six configuration keys. | Stable Hermes adapter passes compatibility tests; default mode is unchanged; opt-in refuses uncheckpointed capture and emits a useful budget warning. | S–M / medium compatibility risk / medium |
| P2 | Derived hierarchical/bitemporal discovery view | Generate an inspectable, rebuildable index grouping existing records by topic/time/validity; never resolve truth or alter OKF. | Delete/rebuild is deterministic; source refs and hashes remain visible; stale index is clearly marked and last-known-good survives failure. | M / medium / medium |
| P2 | Typed provider/index outcome vocabulary | Fill only current gaps with a small enum-like vocabulary (`complete`, `partial`, `degraded`, `unavailable`, `abstained`, `stale`) across CLI JSON and receipts. | Empty, unavailable and abstained outcomes remain distinguishable to callers; existing compatibility payloads remain valid. | S / low / high |

## Defer or reject

Defer graph/database replacement, learned reranking, RL or model-trained memory controllers, multimodal storage without a concrete local use case, reciprocal OpenClaw synchronisation, automatic context-engine adoption, synchronous capture, unmeasured prefetch queues, and global erasure claims. Reject vendor architecture or benchmark scores as authority. These add moving parts without evidence that they improve inspectability, custody, deterministic resolution or Hermes compatibility.

Do not repeat implemented evaluation, provenance, visibility, evidence bundles, promotion gates or typed bridge fields unless a failing fixture demonstrates a gap.

## Phase plan

1. Add P0 receipts, evidence-opened invariant and forget preview as read-only/derived work first.
2. Add masking, contradiction, scope/visibility, metadata-isolation and deletion/provenance probes.
3. Run the existing lifecycle harness and compatibility checks; promote no new canonical knowledge.
4. Consider optional Hermes custody/budgets only after stable-adapter proof; then consider derived discovery views and vocabulary cleanup where measured gaps remain.

## Limitations

This is a delta review, not a benchmark claim or production approval. Main branches can change after the stated snapshots. Academic findings are not transferable guarantees. No live-vault migration, canonical promotion, deployment, release, commit or external write is authorised by this report.

## Sources

Primary sources are linked in the evidence ledger. Additional supplied research context: [arXiv 2604.20006](https://arxiv.org/abs/2604.20006), [arXiv 2608.29605](https://arxiv.org/abs/2608.29605), [arXiv 2605.09530](https://arxiv.org/abs/2605.09530), [PMLR 317](https://proceedings.mlr.press/v317/wu26a.html), [Hermes releases](https://github.com/NousResearch/hermes-agent/releases), and [OpenClaw releases](https://github.com/openclaw/openclaw/releases).
