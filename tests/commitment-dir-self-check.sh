#!/usr/bin/env bash
# Regression: `reflect submit` must not fail in projects created before
# reflection/commitments/ existed, and must keep the candidate pending.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-commitdir.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'commitment dir self-check: %s\n' "$*" >&2; exit 1; }

vault="$fixture/vault"; workspace="$fixture/workspace"; project_id="proj_commit_dir_check"
mkdir -p "$workspace"
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
dir="$vault/projects/$project_id"
rm -rf "$dir/reflection/commitments"

candidate="$fixture/candidate.md"
cat >"$candidate" <<'EOT'
---
type: Reference
title: "Re-checked revision"
brain_review_kind: reference
brain_candidate_id: rev_commit_dir_check
brain_confidence: 0.9
brain_risk: high
brain_sensitivity: internal
brain_provenance: "review://commit-dir-check"
brain_provider_id: "self-check"
brain_provider_version: "1"
brain_source_authority: external-observation
brain_authority_origin: external-observation
brain_supersedes: "okf/references/old.md"
brain_commitment_action: ask
brain_clarification_question: "Approve this revision?"
---
# Re-checked revision

Synthetic revision body.
EOT

out="$("$cli" --root "$vault" reflect submit "$project_id" "$candidate" 2>&1)" || fail "submit failed: $out"
case "$out" in *"No such file or directory"*) fail "submit still writes into a missing directory: $out" ;; esac
review="$dir/review/rev_commit_dir_check.md"
[ -f "$review" ] || fail "review item missing"
state="$(sed -n 's/^brain_review_state: *//p' "$review" | head -1)"
case "$state" in proposed|needs-validation) ;; *) fail "revision was not kept pending (state=$state)" ;; esac
ls "$dir/reflection/commitments"/commitment_*.md >/dev/null 2>&1 || fail "commitment decision record not written"
[ ! -e "$dir/okf/references/rev_commit_dir_check.md" ] || fail "revision was promoted"
[ -z "$(ls "$vault/.locks" 2>/dev/null)" ] || fail "lock left behind"
printf 'commitment dir self-check passed\n'
