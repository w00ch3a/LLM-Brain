# Real-agent evaluation results

These are the measured results behind the numbers in the README. The harness,
task list and method are in [`evals/real/README.md`](../evals/real/README.md).
Each task gives a real coding agent the same work twice, once with Memthena
memory and once without, and grades the result.

- Runner: Codex CLI (codex-cli 0.159.1), default model, memory via the CLI
- 3 repeats per task and condition; 95% intervals are bootstrapped over tasks

## Run 1: coding and research (2026-10-09, 144 runs)

| Family | Group | Memory on | Memory off | Mean task delta | 95% CI |
|---|---|---|---|---|---|
| coding | memory (10 tasks) | 100% | 3% | +97 pts | +90 to +100 pts |
| coding | controls (2 tasks) | 100% | 100% | +0 pts | +0 to +0 pts |
| research | memory (10 tasks) | 27% | 10% | +17 pts | +0 to +40 pts |
| research | controls (2 tasks) | 100% | 100% | +0 pts | +0 to +0 pts |

## Run 2: research after the recall fixes (2026-10-09, 60 runs)

Run 1 showed research recall falling short. The fixes shipped in
[v0.8.2](releases/v0.8.2.md) (corrections and retractions in packs and
briefs, fuller brief summaries); the research family was then run again.

| Family | Group | Memory on | Memory off | Mean task delta | 95% CI |
|---|---|---|---|---|---|
| research | memory (10 tasks) | 67% | 10% | +57 pts | +27 to +87 pts |

In both runs, memory never made a task worse (no task scored lower with
memory on), and control tasks that need no memory passed in both conditions.
Memory-on runs cost more: in run 2, about 43 s versus 29 s of agent time and
about 16% more input tokens per task.

## What is not measured

The 0.9 additions (label lineage, cascading invalidation, recall gates,
sufficiency checks, working memory) have evaluation tasks in
`evals/real/tasks/memorygym.py`, but no real-agent results are published for
them yet.
