# Contributing to LLM-Brain

Thanks for helping improve local-first, inspectable memory for AI agents.

## Good places to start

- Documentation improvements, examples and compatibility notes.
- Small, reproducible fixes with a focused regression check.
- Hermes, Codex, Claude Code and Gemini CLI integration improvements.
- Reports that make provenance, privacy boundaries or failure modes easier to understand.

## Before you open a change

1. Search existing issues and discussions so related work stays together.
2. Keep the change narrow and explain the user or maintainer problem it solves.
3. Use synthetic fixtures only. Do not include vault records, credentials,
   customer or patient data, host-specific paths, or other private material.
4. For security-sensitive reports, follow [`SECURITY.md`](SECURITY.md) instead
   of opening a public issue.

## Local checks

From the repository root, run the checks relevant to the files you changed:

```bash
bash -n bin/llm-brain
bash tests/self-check.sh
bash tests/v3-self-check.sh
git diff --check
```

Source, CLI or data-layer changes should include a runnable regression check.
Documentation-only changes should still have clean links and `git diff --check`.

## Pull requests

Describe the intended behaviour, the files changed, the checks run and any
known limits. Keep canonical memory, source custody and review boundaries
explicit. Do not commit live-vault data or claim that a local check proves
deployment, production safety or model accuracy.

Release, tag, publication and live-vault migration work is maintainer-led and
requires separate approval.
