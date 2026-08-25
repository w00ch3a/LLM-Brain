---
name: llm-brain
description: Automatically use filesystem-first LLM-Brain memory before and after every non-trivial project task, without waiting for the user to name it. Use factual retrieval by default; select current_state explicitly for state resolution, and use commitment policies and target-bound capsules only when requested. Skip automatic use only when LLM_BRAIN_PASSIVE=0.
---

# LLM-Brain

Read and follow the repository's [authoritative LLM-Brain workflow](../../SKILL.md) completely. Hermes remains compatible with `memory.provider: llm-brain` and the optional `context.engine: llm-brain`; preserve its six configuration keys and native compressor defaults. Derived commitment decisions and `runs/prepared/` capsules are not canonical truth, and current-state warnings must remain bounded and fail-open.
