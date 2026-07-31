# Releasing LLM-Brain

`VERSION` is the only package-version authority. Storage schema and OKF version are independent.

## Local release gate

```bash
codex_skills="${CODEX_SKILLS_ROOT:-${CODEX_HOME:-$HOME/.codex}/skills}"
bash -n bin/llm-brain
bash tests/self-check.sh
bash tests/okf-self-check.sh
bash tests/v3-self-check.sh
bash tests/upgrade-self-check.sh
python3 "$codex_skills/.system/skill-creator/scripts/quick_validate.py" skills/llm-brain
python3 "$codex_skills/.system/skill-creator/scripts/quick_validate.py" skills/llm-brain-upgrade
python3 "$codex_skills/.system/plugin-creator/scripts/validate_plugin.py" .
bash scripts/package-ai-skill.sh
bash tests/passive-self-check.sh
git diff --check
```

Verify both archives are byte-reproducible, their checksums match, every Codex/Claude/Gemini manifest equals `VERSION`, and each packaged CLI prints exactly `VERSION`.

After installing the published release, start one fresh Codex, Claude and Gemini session with an ordinary non-trivial project request that does not mention LLM-Brain. Acceptance requires relevant memory retrieval, an authorised closeout capture, the documented opt-out, and one end-user confirmation. Static package checks do not replace this host-session proof.

## Vault migration gate

Live migration is a separate operator-approved action:

```bash
brain_root="${LLM_BRAIN_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/llm-brain/vault}"
bin/llm-brain --root "$brain_root" migrate check
bin/llm-brain --root "$brain_root" lint
```

Present every review, scaffold, custody-gap and OKF transformation count. Never run `migrate apply --all` or `upgrade apply` against the live vault without explicit confirmation of that preflight.

## Publication

Commit, push, tag `v0.4.0`, publish GitHub archives, update public marketplaces or synchronise the configured personal marketplace source only after explicit release authority. After publication, download the published artefacts and repeat checksum, extraction, manifest and packaged-CLI verification in a fresh task.
