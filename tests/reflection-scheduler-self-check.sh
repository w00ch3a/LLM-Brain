#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-reflection.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

vault="$fixture/vault"
project_id="proj_reflection_scheduler_self_check"
"$cli" --root "$vault" project ensure "$repo_root" --id "$project_id" >/dev/null
cat >"$fixture/provider.sh" <<'PROVIDER'
#!/usr/bin/env bash
exit 0
PROVIDER
chmod 755 "$fixture/provider.sh"

printf 'thanks for the update\n' >"$fixture/transient.md"
transient="$(LLM_BRAIN_WORK_AUTORUN=0 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/transient.md" --provider "$fixture/provider.sh")"
grep -Fq 'reflection=deferred reason=low-value-transient' <<<"$transient"
transient_episode="$(printf '%s\n' "$transient" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
transient_ref="${transient_episode#"$vault/projects/$project_id/"}"
schedule="$vault/projects/$project_id/reflection/scheduler/$(basename "$transient_episode" .md).md"
grep -Fq 'brain_reflection_decision: deferred' "$schedule"
grep -Fq 'brain_reflection_reason: "low-value-transient"' "$schedule"
[ "$(find "$vault/projects/$project_id/requests" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = 0 ]

printf 'Correction: deploy-release-v2 is now required and failed once.\n' >"$fixture/important.md"
important="$(LLM_BRAIN_WORK_AUTORUN=0 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/important.md" --provider "$fixture/provider.sh")"
grep -Fq 'reflection=queued reason=async-work schedule_reason=explicit-signal' <<<"$important"
important_episode="$(printf '%s\n' "$important" | sed -n 's/.*episode=\([^ ]*\).*/\1/p' | tail -n 1)"
important_ref="${important_episode#"$vault/projects/$project_id/"}"
status="$($cli --root "$vault" work status "$project_id")"
printf '%s\n' "$status" | awk -F '\t' '$2 == "pending" && $3 == "reflect" { found=1 } END { exit !found }'
"$cli" --root "$vault" work run-once "$project_id" >/dev/null
status="$($cli --root "$vault" work status "$project_id")"
printf '%s\n' "$status" | awk -F '\t' '$2 == "committed" && $3 == "reflect" { found=1 } END { exit !found }'

duplicate="$(LLM_BRAIN_WORK_AUTORUN=0 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/important.md" --provider "$fixture/provider.sh")"
grep -Fq 'reflection=deferred reason=already-reflected' <<<"$duplicate"

printf 'okay\n' >"$fixture/legacy.md"
legacy="$(LLM_BRAIN_REFLECTION_POLICY=legacy LLM_BRAIN_WORK_AUTORUN=0 "$cli" --root "$vault" --cwd "$repo_root" --project-id "$project_id" ingest "$fixture/legacy.md" --provider "$fixture/provider.sh")"
grep -Fq 'reflection=queued reason=async-work schedule_reason=legacy-policy' <<<"$legacy"

printf '%s\n' 'llm-brain reflection scheduler self-check passed'
