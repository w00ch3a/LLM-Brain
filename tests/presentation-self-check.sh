#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
fail() { printf 'presentation self-check: %s\n' "$*" >&2; exit 1; }

help_output="$("$cli" help)"
for phrase in \
  'search PROJECT_ID QUERY' \
  '--intent INTENT' \
  'run prepare PROJECT_ID PROCEDURE_REF' \
  'run start PROJECT_ID PROCEDURE_REF' \
  '--capsule REF' \
  'help | --version'
do
  grep -Fq -- "$phrase" <<<"$help_output" || fail "CLI help omitted: $phrase"
done
[ "$("$cli" --version)" = "$version" ] || fail 'CLI did not report VERSION exactly'

release_notes="docs/releases/v${version}.md"
for path in README.md RELEASING.md SKILL.md references/architecture.md \
  integrations/hermes/llm-brain/README.md install_prompt.md "$release_notes"
do
  [ -s "$repo_root/$path" ] || fail "missing user-facing documentation: $path"
done

grep -Fq 'Current-state retrieval is opt-in' "$repo_root/README.md" ||
  fail 'README does not state current-state opt-in behaviour'
grep -Fq 'LLM_BRAIN_COMMITMENT_POLICY=shadow' "$repo_root/README.md" ||
  fail 'README does not state the shadow default'
grep -Fq 'No vault migration' "$repo_root/$release_notes" ||
  fail 'release notes do not state migration-free upgrade'
grep -Fq 'memory.provider: llm-brain' "$repo_root/integrations/hermes/llm-brain/README.md" ||
  fail 'Hermes documentation lost provider compatibility'
grep -Fq 'fail-open' "$repo_root/integrations/hermes/llm-brain/README.md" ||
  fail 'Hermes documentation lost fail-open behaviour'
grep -Fq 'tests/release-readiness-self-check.sh' "$repo_root/RELEASING.md" ||
  fail 'release guide does not use the aggregate gate'
for path in README.md RELEASING.md SKILL.md references/architecture.md \
  integrations/hermes/llm-brain/README.md install_prompt.md "$release_notes"
do
  if grep -Eq 'tests/v2-self-check.sh|v2-self-check' "$repo_root/$path"; then
    fail "deleted v2 gate is still documented: $path"
  fi
done

plugin_archive="$repo_root/dist/llm-brain-${version}-plugin.tar.gz"
standalone_archive="$repo_root/dist/llm-brain-${version}-standalone.tar.gz"
[ -f "$plugin_archive" ] || fail "missing packaged plugin: $plugin_archive"
[ -f "$standalone_archive" ] || fail "missing packaged standalone archive: $standalone_archive"
plugin_members="$(tar -tzf "$plugin_archive")"
standalone_members="$(tar -tzf "$standalone_archive")"
for member in \
  "llm-brain/README.md" \
  "llm-brain/install_prompt.md" \
  "llm-brain/skills/llm-brain/SKILL.md" \
  "llm-brain/skills/llm-brain/references/architecture.md"
do
  grep -Fqx "$member" <<<"$plugin_members" || fail "plugin omitted packaged documentation: $member"
done
for member in \
  "llm-brain/README.md" \
  "llm-brain/install_prompt.md"
do
  grep -Fqx "$member" <<<"$standalone_members" || fail "standalone archive omitted: $member"
done

printf '%s\n' 'llm-brain presentation self-check passed'
