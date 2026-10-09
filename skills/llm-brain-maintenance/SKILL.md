---
name: llm-brain-maintenance
description: Inspect and run bounded, derived LLM-Brain maintenance reports for freshness, retention candidates, conflicts, provenance, work, receipts and index health. Use only when maintenance is requested; never delete, promote, schedule or alter canonical memory automatically.
---

# LLM-Brain maintenance

Maintenance is an inspectable health view over a project. It is not a second
memory store and it never becomes canonical OKF knowledge.

## Automatic status check

The main `llm-brain` skill performs one bounded, read-only status check after
project resolution for a non-trivial task. It stays silent when the report is
current and emits at most one concise reminder when the report is stale. Set
`LLM_BRAIN_PASSIVE=0` to suppress that check. The automatic path never runs
maintenance, declares a schedule or changes the vault.

## Manual workflow

Use the resolved project ID:

```bash
llm-brain maintenance preview PROJECT_ID --limit 20
llm-brain maintenance status PROJECT_ID --json
llm-brain maintenance run PROJECT_ID --limit 20
```

`preview` and `status` are read-only. `run` atomically replaces only the
derived `projects/PROJECT_ID/maintenance/latest.md` report. Findings are
bounded, principal-visible and labelled as review candidates. They may cover
expiry, stale or unknown validity, conflicts/dependencies, pending or failed
work, malformed receipts, index health, provenance gaps and retraction
residuals. A finding recommends inspection or re-verification; it never
deletes, retracts, promotes or rebuilds anything.

Code drift is also a finding: a concept's `brain_code_anchors: ["path@commit"]`
file changed in the registered source root, so re-verify that concept. A
separate advisory section never changes health. It lists retention candidates
from receipts and feedback (only when usage evidence exists), memory-doctor
orphans, likely duplicates and oversized concepts, spaced re-verification
suggestions and unverifiable anchors. Present advisories as optional review
items. Related read-only views are `usage PROJECT_ID`, `stability show
PROJECT_ID`, `review triage PROJECT_ID` and `association propose PROJECT_ID`.
Only run `stability apply` or `association propose --write-review` when the
user asks.

Status reports `reminder=none`, `run-or-schedule`, `report-stale` or
`unavailable`. The automatic contract only surfaces one concise stale-only
reminder; missing or unavailable status remains fail-open. Use `--strict` when
the caller wants `attention` or `blocked` to return non-zero.

## Host-native scheduling

Record an operator-declared schedule when a host scheduler is already chosen:

```bash
llm-brain maintenance schedule declare PROJECT_ID \
  --name "weekly memory review" --cadence weekly --runner hermes
llm-brain maintenance schedule disable PROJECT_ID
```

This records a derived declaration only. Hermes, Codex or cron remains the
host scheduler and must be configured and verified separately. A declaration
is not proof that a job is active; a recent successful report is the evidence.
No daemon, database, zvec engine, cloud backend or new dependency is needed.

## Safety and compatibility

- Keep `okf/` canonical; reports and schedules are derived Markdown.
- Apply visibility before rendering paths, titles, hashes or counts.
- Keep OKF v0.2, storage schema 3 and factual retrieval defaults unchanged.
- Keep Hermes' `llm-brain` provider, ContextEngine and six-key selector
  contract unchanged. Maintenance is never automatically injected.
- Use `--strict` only when a caller wants a non-zero result for `attention` or
  `blocked`; ordinary status remains fail-open.

Read the [full LLM-Brain workflow](../../SKILL.md) for custody, review and
closeout rules.
