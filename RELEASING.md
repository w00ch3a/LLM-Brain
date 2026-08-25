# Releasing LLM-Brain

`VERSION` is the only package-version authority. Storage schema and OKF version are independent.

## Local release gate

```bash
bash tests/release-readiness-self-check.sh
bash tests/release-readiness-self-check.sh --release
```

The aggregate gate includes the v3, work-queue, reflection-scheduler, temporal, retrieval-planner, procedure, reconsolidation, scope-feedback, experimental, evaluation, compatibility, Hermes, upgrade, packaging and presentation checks. `--release` additionally requires real Hermes source, skill/plugin validators and the packaged Hermes plugin. The v3 gate is authoritative; the deleted legacy gate must not be called.

The Hermes checks verify `hermes memory setup llm-brain`, `load_memory_provider("llm-brain")`, both registrations, the unchanged six configuration keys and any saved configuration. Optional `llm_brain_search` intent is additive, while provider capture, ContextEngine sole-injector behaviour, native compressor inheritance and fail-open recall remain compatibility checks.

Verify both archives are byte-reproducible, their checksums match, every Codex/Claude/Gemini manifest equals `VERSION`, and each packaged CLI prints exactly `VERSION`.

For Codex, test both marketplace source types: a local marketplace must consume the verified plugin archive without running a Git refresh, while a Git marketplace must refresh natively. Treat a host inventory failure as a blocker; never fall back to a different installation type when detection is incomplete.

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

Commit, push, tag the version declared by `VERSION`, publish GitHub archives, update public marketplaces or synchronise the configured personal marketplace source only after explicit release authority. After publication, download the published artefacts and repeat checksum, extraction, manifest and packaged-CLI verification in a fresh task.

Release proof is four separate checks: the intended commit is on the public branch, the tag resolves to that commit, the GitHub Release exists with both archives and checksum assets, and a normal release-based `upgrade check` resolves the published checksum. Local installation or a pushed feature branch does not prove publication.
