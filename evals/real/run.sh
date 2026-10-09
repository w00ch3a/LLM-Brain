#!/usr/bin/env bash
# LLM-Brain real evaluation: memory on vs off, run with Codex CLI.
#
#   ./run.sh OUTPUT_DIR --dry-run          prepare/seed every task, write prompts + codex commands, no model calls
#   ./run.sh OUTPUT_DIR --smoke            1 coding + 1 research task, on/off, 1 repeat (4 codex runs + 1 preflight)
#   ./run.sh OUTPUT_DIR                    full suite: 24 tasks x 2 conditions x 3 repeats (144 codex runs + 1 preflight)
#   ./run.sh OUTPUT_DIR --resume           continue an interrupted run in the same OUTPUT_DIR
#   ./run.sh OUTPUT_DIR --report-only      rebuild summary.md / summary.json from results.jsonl
#
# Other options (see --help): --model M, --repeats N, --jobs N, --timeout SECONDS,
# --tasks id1,id2, --family coding|research, --memory-mode cli|inject,
# --codex PATH, --codex-home isolated|shared, --codex-config KEY=VALUE, --runner reference.
#
# Installs LLM-Brain 0.8.0 (standalone archive, checksum-verified) under this
# bundle's .local/ only. Never touches ~/.codex config, your PATH or any real brain.
set -eu
here="$(cd "$(dirname "$0")" && pwd -P)"
if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  [ $# -ge 1 ] && exec python3 "$here/eval_real.py" --help
  exit 64
fi
case "$1" in -*) echo "run.sh: first argument must be the output directory" >&2; exit 64 ;; esac
out="$1"; shift
command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 is required" >&2; exit 69; }
command -v git >/dev/null 2>&1 || { echo "run.sh: git is required" >&2; exit 69; }
exec python3 "$here/eval_real.py" --bundle "$here" --output "$out" "$@"
