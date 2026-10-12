# Development / unreleased

This file tracks changes after v0.9.0. It is not a release, installation,
deployment or live-vault migration record. `VERSION` is the package-version
authority.



See the [v0.9.0 release notes](v0.9.0.md)
for shipped changes and the [evaluation guide](../evaluation.md) for measured
versus unmeasured outcomes.

## Since v0.9.0

- Hermes `/neural-expansion` and the dashboard page now write to
  `$HERMES_HOME/neural-expansion/` instead of `$HERMES_HOME/llm-brain/neural-expansion/`
  (on installs where `$HERMES_HOME/llm-brain` is a symlink to the vault, 0.9.0
  wrote demo pages into the vault). Output inside the vault, or on a
  filesystem that does not keep 0700/0600 modes, is now refused.
