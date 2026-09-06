---
name: llm-brain-upgrade
description: Upgrade LLM-Brain when the user asks to upgrade, update, migrate or refresh LLM-Brain, its plugin, extension, OKF format or configured vaults. Perform one read-only preflight, ask once before writes, then update the existing trusted host source, verify and retain receipt-based rollback. v0.6.2 is migration-free unless a separate migration is explicitly authorised.
---

# LLM-Brain upgrade

Upgrade the installed package and configured vaults as one transaction.

## Safety boundary

- Treat `upgrade check` as read-only.
- Do not change marketplaces, package sources or vault identities during an upgrade.
- Never scan the filesystem for vaults. Use the user root registry, `LLM_BRAIN_ROOT`, the platform default and explicit roots only.
- Never run a live migration until the user confirms the complete preflight once.
- The v0.6.2 package changes no storage schema and does not require vault migration; keep `migrate check` separate unless migration authority is explicit.
- Keep unresolved review and custody gaps visible. Do not normalise them into success.
- Do not commit, push, tag, publish or refresh public marketplaces without separate release authority.

## Workflow

1. Locate the installed `llm-brain` executable and run:

   ```bash
   llm-brain upgrade check --all --host auto --target TARGET
   ```

2. Present the output without dropping any vault, lock, capacity, conformance, review, source-gap, backup, rollback or restart detail.
3. Ask one confirmation covering the package/runtime/adapter writes and every listed vault.
4. After confirmation, pass the exact preflight hash:

   ```bash
   llm-brain upgrade apply --all --host auto --target TARGET --plan-hash HASH
   ```

5. Verify the returned receipt:

   ```bash
   llm-brain upgrade verify --receipt RECEIPT
   ```

6. Report the receipt path and whether the host must reload or restart.

The apply command recomputes the plan and aborts on drift. It installs the hash-locked YAML runtime, uses the detected host's native update command, verifies the package and adapter without changing the v0.6.2 vault schema, restores changed package state on failure, and leaves sibling rollback trees plus the receipt. Any requested vault migration remains a separate, explicitly authorised operation.

For an explicit later rollback:

```bash
llm-brain upgrade rollback --receipt RECEIPT
```

Rollback is fail-closed when a vault changed after the verified upgrade. Inspect that drift instead of overwriting it.
