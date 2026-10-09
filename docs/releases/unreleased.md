# Development / unreleased

This file tracks changes after v0.8.0. It is not a release, installation,
deployment or live-vault migration record. `VERSION` is the package-version
authority.

- Fixed `pack build` failing with "File name too long" when `--task` text is
  long. The task part of the pack file name is now capped at 80 characters,
  and the hash suffix keeps names unique. The real-agent evaluation found this.
- Added the real-agent evaluation suite in `evals/real/`, with
  `tests/real-eval-self-check.sh`. It runs 24 synthetic coding and research
  tasks with memory on and off through `codex exec`. Hidden tests and a
  deterministic answer key do the grading.

See the [v0.8.0 release notes](v0.8.0.md)
for shipped changes and the [evaluation guide](../evaluation.md) for measured
versus unmeasured outcomes.
