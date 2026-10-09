# LLM-Brain real evaluation: memory on vs off (Codex CLI)

This suite measures whether LLM-Brain 0.8.0 memory changes real agent outcomes.
Each task runs twice:

- **off**: the agent gets only the repository or question.
- **on**: the agent gets the same prompt plus an LLM-Brain brain seeded with
  prior-session knowledge, and is told to use `llm-brain brief`, `pack build`
  and `search`.

Grading never uses a model. Coding tasks are scored by hidden executable
tests, which are copied in only after the agent finishes. Research tasks are
scored by a deterministic answer key over `answer.json`. A "does not cite"
check may carry `unless_regex`: naming a withdrawn source is allowed when the
answer says it is withdrawn (r10; r09's own reference answer cites the
withdrawn dataset next to its withdrawal notice).

All content is synthetic.

## Quick start (macOS, Codex CLI)

```bash
tar -xzf llm-brain-real-eval.tgz
cd llm-brain-real-eval
./run.sh ~/llm-brain-eval/dry --dry-run       # no model calls: install, seed, fairness checks, prompts
./run.sh ~/llm-brain-eval/smoke --smoke       # 1 preflight + 4 codex runs
./run.sh ~/llm-brain-eval/full                # 1 preflight + 144 codex runs (24 tasks x 2 x 3)
./run.sh ~/llm-brain-eval/full --resume       # continue after an interruption
```

Add `--model MODEL` to pin a model. Add `--codex-config KEY=VALUE` for other
`codex exec -c` overrides, such as `model_reasoning_effort="medium"`. Results go
to `OUTPUT/summary.md`, `summary.json`, `results.jsonl` and `runs/<run-id>/`
(prompt, codex events, final message, diff or answer, commands).

Requirements: `python3` >= 3.9, `git`, and Codex CLI. The default Codex path is
`~/.local/bin/codex`; override it with `--codex PATH`. The tarball also
contains the checksum-verified LLM-Brain 0.8.0 standalone archive and a
vendored pure-Python PyYAML 6.0.3 that matches the release lock hash.
Nothing is installed globally.

## Task families

| Family | Tasks | What memory carries |
|---|---|---|
| Coding (`tasks/coding.py`) | 10 memory + 2 controls | Conventions, past decisions, gotchas, a superseded fact, a renamed flag (correction), a deprecated API, a path-scoped rule (`brain_paths`) |
| Research (`tasks/research.py`) | 10 memory + 2 controls | Two synthetic projects with sourced findings, conflicting sources, a correction (supersession), a retraction (`llm-brain retract`), a decision and open intentions |

Controls:

- `c11` and `r12` are tasks where memory is irrelevant.
- `c12` and `r06` are **harm controls**. Memory there is deliberately stale and
  contradicts the current files, which must win.

A research answer passes only when all of these hold:

- the JSON has every requested key;
- the required facts are present;
- superseded or retracted facts are absent;
- the required source IDs are cited;
- no source ID outside the project's real set is cited or mentioned.

## Fairness and isolation

- Each run gets a fresh temporary root outside the bundle and output folders,
  containing `work/` (the git repo), `brain/` (memory-on only), `home/`, `tmp/`,
  `bin/` and `opt/`. The root is deleted after grading. Use `--keep-roots` to
  keep it for debugging.
- Before the agent starts, the off and on work trees are byte-identical. This
  is checked and reported. Every task also lists `memory_only` markers, which
  must not appear in its files or base prompt; the run refuses to start
  otherwise.
- The agent's environment is rebuilt from scratch:
  - `HOME`, `TMPDIR` and the XDG folders are private.
  - `PATH` contains only `ROOT/bin` and the system folders, so your real
    `~/.local/bin/llm-brain` is unreachable.
  - The memory-on `llm-brain` is a private copy in `ROOT/opt`, with no path
    back to this bundle.
- Codex runs as `codex exec --sandbox workspace-write` with network access off.
  The writable roots are `work/` plus that run's `brain/`, `tmp/` and `home/`.
  Approvals are `never`.
- `--codex-home isolated` is the default. It creates a temporary `CODEX_HOME`
  inside the output folder, copies in only `auth.json`, and deletes it at the
  end. Your `config.toml`, global `AGENTS.md`, MCP servers, plugins and hooks
  (including an installed LLM-Brain plugin) cannot leak into either condition.
  If you sign in through the keychain or an API key instead of `auth.json`, set
  `OPENAI_API_KEY`/`CODEX_API_KEY` or use `--codex-home shared`. Shared mode
  uses your real Codex home, so a globally installed LLM-Brain plugin or
  instructions would contaminate the off condition.
- Codex's macOS sandbox blocks writes and network access, but **not reads**
  elsewhere on disk. The harness flags any agent command that touches the
  bundle, the output folder or another run's root (`contamination_flags`).
  Inspect any flagged runs.

## Reading the summary

- **Pass rates** are shown per family. Memory tasks and controls are reported
  separately. The delta is the mean per-task (on minus off), with a bootstrap
  95% interval across tasks.
- **Per-task table**: passes per condition, the delta, and the mean partial
  score. The partial score is the fraction of research checks passed.
- **Cost**: mean agent seconds, and input, cached input and output tokens
  (from `codex exec --json` usage events), plus the number of commands.
- **Integrity**:
  - how many memory-on runs actually called `llm-brain`;
  - failed `llm-brain` calls;
  - tasks where memory hurt;
  - contamination flags;
  - unequal work trees;
  - errors.

## Verifying the wiring without a model

`./run.sh OUT --runner reference` uses a scripted agent. In memory-on runs it
calls the real CLI (brief, pack and search) and applies the correct solution
only if the retrieved text contains the needed knowledge. Otherwise it applies a
plausible naive solution. It also fails if superseded or retracted memory
surfaces. The expected result is that memory tasks score 100% on and 0% off,
and controls score 100% in both conditions.
