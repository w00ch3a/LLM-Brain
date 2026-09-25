## Summary

<!-- What problem does this change solve? Keep the scope narrow and concrete. -->

## Change type

- [ ] Bug fix
- [ ] Feature
- [ ] Documentation
- [ ] Maintenance or tooling
- [ ] Other (explain below)

## Scope and safety

- [ ] I searched for existing issues or discussions and kept this change focused.
- [ ] I used synthetic fixtures only; no vault records, credentials, customer or patient data, or private infrastructure details are included.
- [ ] I considered privacy, security, accessibility and backwards compatibility where relevant.
- [ ] Any security-sensitive detail is reported privately through `SECURITY.md`.

## Verification

List the checks you ran and their results. For source, CLI or data-layer changes,
run the checks required by `CONTRIBUTING.md`.

- [ ] `git diff --check`
- [ ] `bash -n bin/llm-brain` (source, CLI or data-layer changes)
- [ ] `bash tests/self-check.sh` (source, CLI or data-layer changes)
- [ ] `bash tests/v3-self-check.sh` (source, CLI or data-layer changes)
- [ ] Documentation-only change; relevant links and formatting checked
- [ ] Not applicable (explain why below)

## Known limits

<!-- Note skipped checks, assumptions, follow-up work or evidence gaps. -->
