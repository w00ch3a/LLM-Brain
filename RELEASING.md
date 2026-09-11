# Releasing LLM-Brain

`VERSION` is the only package-version authority. Storage schema and OKF version are independent.

The current storage schema is 3 and canonical knowledge is OKF v0.2. Receipts
are opt-in; verify retraction as a preview/confirm operation without mutating a
live vault. Do not describe evaluation-only portability, repair or research
results as production guarantees, or an unreleased change as published.

LLM-Brain is distributed under Apache License 2.0, subject to its disclaimers
and applicable-law limits. Users remain responsible for installation,
validation and deployment; release checks are not guarantees.

## Local release gate

```bash
bash tests/release-readiness-self-check.sh
bash tests/release-readiness-self-check.sh --release
```

The aggregate gate includes the v3, work-queue, reflection-scheduler, temporal, retrieval-planner, procedure, capsule-dependency, lifecycle-evidence, poisoning, ground-truth evaluation, reconsolidation, scope-feedback, experimental, compatibility, Hermes, upgrade, packaging and presentation checks. `--release` additionally requires real Hermes source, skill/plugin validators and the packaged Hermes plugin. The v3 gate is authoritative; the deleted legacy gate must not be called.

The capsule checks must prove that preparation records the declared dependency closure, read-only validation detects changed, hidden, expired and unresolved dependencies, start rechecks under the project lease, and unrelated changes do not stale a capsule. Dependency-free legacy capsules retain compatibility; capsules that depend on state records must be re-prepared before use.

The lifecycle evidence checks must prove bounded deterministic traversal, role-labelled support/conflict/history/derivation, visibility filtering and warning-first handling of incomplete relationships. Shared state keys do not establish supersession, and bundle expansion never rewrites canonical memory or increases authority.

The poisoning checks use disposable vaults. They attempt authority laundering, restricted-evidence disclosure and poisoned procedure validation, then exercise the existing quarantine/retraction/repair paths and confirm that unrelated custody remains intact. These are regression checks for the implemented policy, not a claim of universal prompt-injection resistance.

The ground-truth lifecycle evaluator runs twelve scenario families at 20-event and 200-event checkpoints. It seeds expected state before rendering conversations, compares six modes—`none`, `raw-source`, `factual`, `explicit` (`current_state`), `evidence` and `historical`—and records deterministic traces. Checkpoints score stale-result leakage, provenance-root independence, repair isolation, capsule preparation/validation and poisoning resistance, alongside candidate hits, unresolved state, context/token estimates, latency, degradation, operation/write cost and repeat reliability. Reports must distinguish these ground-truth metrics from optional answer-runner outcomes; model-answer accuracy remains unmeasured when no runner is configured. An answer runner is a trusted local executable with no OS sandbox requirement; it receives bounded question/evidence data while expected paths and fixture truth remain host-side. Evaluation artefacts are derived and must never be promoted as canonical memory. See `docs/evaluation.md`.

The Hermes checks verify `hermes memory setup llm-brain`, `load_memory_provider("llm-brain")`, both registrations, the unchanged six configuration keys and any saved configuration. Optional `llm_brain_search` intent is additive, while provider capture, ContextEngine sole-injector behaviour, native compressor inheritance and fail-open recall remain compatibility checks.

Verify both archives are byte-reproducible, their checksums match, every Codex/Claude/Gemini manifest equals `VERSION`, each packaged CLI prints exactly `VERSION`, and packaged docs include the release notes and Hermes/OpenClaw comparison report while describing dependency validation, bounded evidence bundles, poisoning-test limits and the ground-truth evaluator without claiming a release or live-vault migration.

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
