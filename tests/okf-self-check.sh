#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/lib/okf.py"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'okf self-check: %s\n' "$*" >&2; exit 1; }
contains() { printf '%s' "$1" | grep -Fq "$2" || fail "expected: $2"; }
tree_hash() {
  local root="$1"
  (
    cd "$root"
    find . -type f | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\t' "$file"
      shasum -a 256 "$file" | awk '{print $1}'
    done
  ) | shasum -a 256 | awk '{print $1}'
}

bundle="$fixture/okf"
mkdir -p "$bundle/computations" "$bundle/metrics"
cat >"$bundle/index.md" <<'INDEX'
---
okf_version: "0.2"
---
# Example bundle

* [Revenue](computations/revenue.md) - Attested revenue.
INDEX
cat >"$bundle/log.md" <<'LOG'
# Directory Update Log

## 2026-07-31
* **Creation**: Added the example.
LOG
cat >"$bundle/metrics/revenue.md" <<'METRIC'
---
type: Metric
title: Revenue
description: Recognized revenue for a fiscal year.
tags: [finance, revenue]
status: stable
generated: {by: reference_agent/gemini-2.5-pro, at: 2026-06-20T22:53:05Z}
---
# Definition

Recognized revenue sums `amount` over rows booked to the fiscal year,
computed by [the revenue computation](../computations/revenue.md).
METRIC
cat >"$bundle/computations/revenue.md" <<'COMPUTATION'
---
type: Attested Computation
title: Revenue for fiscal year
description: Recognized revenue for a fiscal year, per Finance's definition.
status: stable
runtime: bigquery
parameters:
  - { name: year, type: integer, required: true }
executor:
  resource: references/skills/run-on-bq.md
  receipt: [job_id, executed_sql, result]
attester:
  resource: references/attesters/revenue.py
generated: { by: reference_agent/gemini-2.5-pro, at: 2026-06-20T22:53:05Z }
verified: { by: human:ahormati, at: 2026-06-25T09:00:00Z }
stale_after: 2026-09-23
sources:
  - id: rev-policy
    resource: https://wiki.acme/finance/revenue-recognition
    title: Revenue recognition policy
---
# Computation

    SELECT SUM(amount) AS revenue
    FROM finance.recognized_revenue
    WHERE fiscal_year = @year

The computation binds only the declared `parameters`, per the recognition
policy.[^rev-policy]

[^rev-policy]: Revenue recognition policy
COMPUTATION

contains "$(python3 "$helper" validate-bundle "$bundle")" 'errors=0'
contains "$(python3 "$helper" facts "$bundle/metrics/revenue.md")" $'unverified\tunspecified'
contains "$(python3 "$helper" facts "$bundle/computations/revenue.md")" $'Attested Computation\tRevenue for fiscal year'
roundtrip="$fixture/revenue-roundtrip.md"
cp "$bundle/computations/revenue.md" "$roundtrip"
body_before="$(awk 'BEGIN{seen=0} /^---[[:space:]]*$/{seen++; next} seen >= 2{print}' "$roundtrip" | shasum -a 256 | awk '{print $1}')"
python3 "$helper" migrate-concept "$roundtrip" --actor llm-brain-migration/0.4.0 --at 2026-07-31T00:00:00Z >/dev/null
body_after="$(awk 'BEGIN{seen=0} /^---[[:space:]]*$/{seen++; next} seen >= 2{print}' "$roundtrip" | shasum -a 256 | awk '{print $1}')"
[ "$body_before" = "$body_after" ] || fail "official Attested Computation body changed during round trip"

invalid="$fixture/invalid"
mkdir -p "$invalid"
cp "$bundle/index.md" "$invalid/index.md"
cp "$bundle/log.md" "$invalid/log.md"
cat >"$invalid/duplicate.md" <<'DUPLICATE'
---
type: Claim
type: Procedure
---
# Duplicate
DUPLICATE
if python3 "$helper" validate-bundle "$invalid" >/dev/null 2>&1; then fail "duplicate YAML key passed"; fi
cat >"$invalid/duplicate.md" <<'ACTOR'
---
type: Claim
generated: {by: invalid-actor, at: 2026-07-31T00:00:00Z}
---
# Invalid actor
ACTOR
if python3 "$helper" validate-bundle "$invalid" >/dev/null 2>&1; then fail "invalid actor passed"; fi
cat >"$invalid/duplicate.md" <<'MISSING'
---
title: Missing type
---
# Missing type
MISSING
if python3 "$helper" validate-bundle "$invalid" >/dev/null 2>&1; then fail "missing type passed"; fi
reserved_invalid="$fixture/reserved-invalid"
mkdir -p "$reserved_invalid"
cp "$bundle/log.md" "$reserved_invalid/log.md"
cat >"$reserved_invalid/index.md" <<'BAD_RESERVED'
---
okf_version: [unterminated
---
# Broken
BAD_RESERVED
if python3 "$helper" validate-bundle "$reserved_invalid" >/dev/null 2>&1; then fail "malformed reserved YAML passed"; fi
contains "$(python3 "$helper" audit "$reserved_invalid")" 'malformed_frontmatter=1'

legacy="$fixture/legacy"
mkdir -p "$legacy/topics"
cat >"$legacy/index.md" <<'LEGACY_INDEX'
---
type: Project
title: Legacy project
brain_review_state: approved
unknown_project_key: keep-me
timestamp: 2026-05-28T22:53:05Z
---
# Legacy project
LEGACY_INDEX
printf '# Log\n\n- 2026-07-30: legacy update\n' >"$legacy/log.md"
cat >"$legacy/metric.md" <<'LEGACY_METRIC'
---
type: Metric
title: Legacy metric
brain_review_state: approved
unknown_extension: keep-me
timestamp: 2026-05-28T22:53:05Z
---
# Legacy metric

# Citations

- https://example.invalid/source
- all queries in example project
LEGACY_METRIC
cat >"$legacy/topics/legacy.md" <<'LEGACY_TOPIC'
---
title: Legacy topic
brain_review_state: proposed
---
# Legacy topic
LEGACY_TOPIC
mkdir -p "$legacy/retractions"
cat >"$legacy/retractions/legacy.md" <<'LEGACY_RETRACTION'
---
type: Retraction
title: Legacy retraction
brain_review_state: superseded
---
# Legacy retraction
LEGACY_RETRACTION
mkdir -p "$legacy/references"
cat >"$legacy/references/legacy.md" <<'LEGACY_REFERENCE'
---
title: Legacy reference
brain_review_state: approved
---
# Legacy reference
LEGACY_REFERENCE
python3 "$helper" migrate-bundle "$legacy" --project-id proj_legacy --title Legacy --actor llm-brain-migration/0.4.0 --at 2026-07-31T00:00:00Z
contains "$(python3 "$helper" validate-bundle "$legacy")" 'errors=0'
contains "$(cat "$legacy/index.md")" 'okf_version: "0.2"'
contains "$(cat "$legacy/project.md")" 'unknown_project_key: keep-me'
contains "$(cat "$legacy/metric.md")" 'brain_legacy_timestamp:'
contains "$(cat "$legacy/metric.md")" 'unknown_extension: keep-me'
contains "$(cat "$legacy/metric.md")" 'sources:'
contains "$(cat "$legacy/metric.md")" 'brain_legacy_citation_scopes:'
contains "$(cat "$legacy/metric.md")" 'all queries in example project'
if grep -Fq '# Citations' "$legacy/metric.md"; then fail "legacy citations heading remained"; fi
contains "$(cat "$legacy/topics/legacy.md")" 'type: Topic'
contains "$(cat "$legacy/topics/legacy.md")" 'status: draft'
contains "$(cat "$legacy/retractions/legacy.md")" 'status: stable'
contains "$(cat "$legacy/references/legacy.md")" 'type: Reference'
if grep -Fq 'verified:' "$legacy/project.md"; then fail "approval was mapped to false verification"; fi

vault="$fixture/vault"
repo="$fixture/repo"
mkdir -p "$vault" "$repo"
git -C "$repo" init -q
project="$($cli --root "$vault" project ensure "$repo" --id proj_okf | sed -n 's/.*project_id=\([^ ]*\).*/\1/p')"
cp "$bundle/computations/revenue.md" "$vault/projects/$project/okf/computations/revenue.md"
mkdir -p "$vault/projects/$project/okf/metrics"
cp "$bundle/metrics/revenue.md" "$vault/projects/$project/okf/metrics/revenue.md"
$cli --root "$vault" index build "$project" >/dev/null
contains "$(cat "$vault/projects/$project/indexes/documents.tsv")" $'Attested Computation\tRevenue for fiscal year'
contains "$($cli --root "$vault" search "$project" 'fiscal year')" 'human-reviewed'
$cli --root "$vault" lint --strict >/dev/null
bundle_path="$($cli --root "$vault" export bundle "$project" | sed -n 's/^export=bundle path=//p')"
import_vault="$fixture/import-vault"
import_repo="$fixture/import-repo"
mkdir -p "$import_repo"
git -C "$import_repo" init -q
$cli --root "$import_vault" project ensure "$import_repo" --id "$project" >/dev/null
rm -rf "$import_vault/projects/$project/okf"
mkdir -p "$import_vault/projects/$project/okf"
$cli --root "$import_vault" --project-id "$project" import bundle "$bundle_path" --apply >/dev/null
[ "$(tree_hash "$vault/projects/$project/okf")" = "$(tree_hash "$import_vault/projects/$project/okf")" ] ||
  fail "official OKF v0.2 bundle changed during export/import"
$cli --root "$import_vault" lint --strict >/dev/null

printf 'llm-brain OKF v0.2 self-check passed\n'
