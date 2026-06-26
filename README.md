# LLM-Brain

LLM-Brain is a reusable skill/specification for building a durable, repository-agnostic memory system for AI coding agents.

It is not Codex-only. Codex is one supported client/adapter alongside Claude Code, Hermes, OpenClaw, and generic Agent Skills clients.

It is not a larger prompt, a transcript archive, or a prettier wiki. The goal is to create a portable brain for a project: one that remembers what happened, promotes reviewed knowledge into durable files, preserves provenance, detects conflicts, and generates task-specific context for different agents.

The current repository contains the skill prompt in [`SKILL.md`](SKILL.md). It is a specification for an agent to inspect a target repository and build the most native implementation for that stack.

## What It Does

LLM-Brain guides an agent to add a filesystem-first memory layer to any project.

It can be invoked to:

- bootstrap a new project brain,
- extend an existing project brain,
- create a scoped topic or thread brain under a project,
- capture episodes from work sessions,
- extract candidate claims, procedures, references, and decisions,
- promote reviewed knowledge into an OKF-style canonical bundle,
- keep raw episodes separate from approved durable knowledge,
- build lexical, vector, and graph-style retrieval surfaces,
- generate context packs for agents such as Codex, Claude Code, Hermes, OpenClaw, and generic Agent Skills clients,
- generate or update adapter files such as `AGENTS.md`, `SKILL.md`, and related project guidance,
- export canonical knowledge into Knowledge Catalog / Documents Layout friendly structures.

## Why It Exists

Most agent memory systems confuse more context with better memory. LLM-Brain treats them as different things.

- **Context** is the bounded information loaded for one run.
- **Memory** is durable information stored outside the model and reused later.
- **A wiki** stores curated pages.
- **A brain** stores pages, episodes, provenance, confidence, conflicts, review state, indexes, procedures, and agent-specific context packs.

The strongest default is to use Open Knowledge Format (OKF) as the canonical human-readable knowledge layer, then build the missing brain machinery around it.

## Core Model

LLM-Brain uses five layers.

| Layer | Purpose | Default Shape |
| --- | --- | --- |
| Episodic memory | What happened, when, and with what source | Append-only event records |
| Semantic memory | Approved durable project knowledge | OKF-style Markdown files with YAML frontmatter |
| Procedural memory | Reusable workflows and skills | Focused Agent Skills / `SKILL.md` packages |
| Retrieval memory | Fast lookup and recall | Lexical, vector, and relationship indexes |
| Governance | Trust, safety, and auditability | Review queues, provenance, conflicts, redaction, migrations |

The semantic layer is the source of truth. Indexes, context packs, exports, and agent adapters are derived artifacts.

## Architecture

The skill asks the agent to build the smallest native implementation that fits the target repository. A mature implementation normally includes:

- project resolver,
- file-backed registry manager,
- OKF bundle manager,
- episode writer,
- claim extractor,
- procedure extractor,
- review queue,
- promotion engine,
- relation graph builder,
- lexical indexer,
- vector indexer,
- context-pack builder,
- agent adapter generator,
- Knowledge Catalog exporter,
- secret scanner,
- migration tooling,
- tests and routing evals.

For a small project, this can start as a simple filesystem sidecar. For a larger project, the same model can use existing project infrastructure for CLIs, queues, indexes, or APIs.

## Expected Filesystem Shape

The exact layout should match the target repository, but the conceptual shape is:

```text
llm-brain/
  registry/
  projects/
    <project-id>/
      index.md
      log.md
      concepts/
      claims/
      procedures/
      episodes/
      review/
      indexes/
      context-packs/
      adapters/
      exports/
      migrations/
```

Everything important should remain inspectable, diffable, and portable. Opaque databases can be used as rebuildable indexes, but they should not become the only source of truth.

## Governance Defaults

LLM-Brain is deliberately conservative about promotion.

- Capture should be easy.
- Promotion should be reviewable.
- Raw episodes are not canonical truth.
- Newer claims must not silently overwrite older conflicting claims.
- High-risk knowledge and generated skills should go through review.
- Secrets and credentials must be scanned before promotion.
- Sensitive knowledge must not leak into low-trust context packs.
- Deletion should prefer tombstones or retraction markers when provenance matters.

## Context Packs

A context pack is a derived view over the brain for a specific task and agent.

Packs can be filtered by:

- agent type,
- task,
- token budget,
- scope,
- recency,
- confidence,
- review state,
- sensitivity.

The pack should include only what the agent needs, with pointers for expansion. It is disposable and rebuildable. It is not the brain.

## Usage

Use this repository as the source skill/specification for an agent that supports skills or project instructions.

Typical flow:

1. Install or reference [`SKILL.md`](SKILL.md) in the agent environment.
2. Invoke the skill in a target repository.
3. Let the agent inspect the repository before choosing an implementation path.
4. Bootstrap a project brain or add a scoped topic brain.
5. Review generated claims, procedures, adapters, indexes, and context packs.
6. Promote only reviewed knowledge into canonical semantic memory.

Example invocations:

```text
Use the LLM-Brain skill to bootstrap durable project memory for this repo.
```

```text
Use LLM-Brain to create a scoped topic brain for the payment idempotency design thread.
```

```text
Use LLM-Brain to build a Codex context pack for the current migration task.
```

## Current Status

This repository currently contains the reusable skill prompt and license only. It does not yet ship a packaged CLI or reference implementation.

The skill is intentionally stack-neutral: when used inside another repository, it should reuse that repository's language, tooling, tests, and conventions instead of forcing a new runtime.

## Design Principles

- Durable over convenient.
- Inspectable over opaque.
- Portable over vendor-specific.
- Reviewable over magical.
- Filesystem-first by default.
- Repository-native implementation.
- Generated adapters are not the source of truth.
- OKF is the canonical semantic layer, not the whole brain.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
