# Releasing LLM-Brain

`VERSION` is the only package-version authority. The plugin manifest must match it. Storage schema is independent and lives in project `schema.version` files.

## Local release gate

```bash
bash -n bin/llm-brain
bash -n tests/self-check.sh
bash -n tests/v2-self-check.sh
tests/self-check.sh
tests/v2-self-check.sh
git diff --check
scripts/package-ai-skill.sh
```

Run ShellCheck when available:

```bash
shellcheck bin/llm-brain scripts/package-ai-skill.sh tests/*.sh
```

The package command produces each archive twice, requires byte-identical bytes, verifies safe members, extracts it and checks the packaged CLI. Inspect the generated checksum files in `dist/`.

## Vault migration gate

Before a live migration, obtain explicit authority and run:

```bash
bin/llm-brain --root /Volumes/home/Vaults/llm-brain migrate check
bin/llm-brain --root /Volumes/home/Vaults/llm-brain lint
```

`migrate apply --all` makes sibling snapshot/staging/rollback trees and a local tar backup before cutover. Keep snapshot, rollback and backup paths until post-release acceptance. Never claim a migration completed without its strict post-cutover verification output.

## External publication

Commit, push, tag, create a GitHub release, publish an archive or reinstall a plugin only with explicit authority. After publication, download or extract the published artefact and repeat the packaged CLI check in a fresh task.
