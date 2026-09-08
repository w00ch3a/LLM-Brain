#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-openclaw.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() {
  printf 'OpenClaw adapter self-check: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  grep -Fq -- "$2" <<<"$1" || fail "expected output to contain: $2"
}

tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    if path.is_file() and not path.is_symlink():
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
print(digest.hexdigest())
PY
}

workspace="$fixture/workspace"
vault="$fixture/vault"
project_id="proj_openclaw_self_check"
profile_root="$fixture/openclaw-profile"
mkdir -p "$workspace" "$vault" "$profile_root/memory"
git -C "$workspace" init -q
git -C "$workspace" remote add origin https://example.invalid/llm-brain-openclaw.git
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null
project_dir="$vault/projects/$project_id"

cat >"$profile_root/memory/note.md" <<'EOF'
# OpenClaw fixture note

Synthetic external observation content.
EOF

cat >"$profile_root/profile.json" <<'EOF'
{
  "version": "2026.9.2",
  "profile_id": "openclaw-memory-core-2026.9.2",
  "scope": "project",
  "external_observation": true,
  "canonical_write": false,
  "reciprocal_write": false,
  "entries": [
    {
      "path": "memory/note.md",
      "source_type": "markdown",
      "observed_at": "2026-09-07T00:00:00Z",
      "resource": "synthetic-openclaw-fixture"
    }
  ]
}
EOF

canonical_before="$(
  tree_digest "$project_dir/okf"
)"

if disabled_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=0 "$cli" --root "$vault" adapters openclaw inspect "$project_id" "$profile_root" 2>&1
)"; then
  fail "disabled OpenClaw adapter unexpectedly ran"
fi
assert_contains "$disabled_output" 'OpenClaw adapter is disabled'
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before" ] || fail "disabled adapter mutated canonical OKF"

cat >"$fixture/bad-version.json" <<'EOF'
{
  "version": "2026.9.1",
  "profile_id": "openclaw-memory-core-2026.9.2",
  "scope": "project",
  "entries": []
}
EOF
if bad_version_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw inspect "$project_id" "$fixture/bad-version.json" 2>&1
)"; then
  fail "unsupported OpenClaw version unexpectedly passed"
fi
assert_contains "$bad_version_output" 'unsupported OpenClaw version'

cat >"$fixture/bad-profile.json" <<'EOF'
{
  "version": "2026.9.2",
  "profile_id": "openclaw-memory-core-legacy",
  "scope": "project",
  "entries": []
}
EOF
if bad_profile_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw inspect "$project_id" "$fixture/bad-profile.json" 2>&1
)"; then
  fail "unsupported OpenClaw profile unexpectedly passed"
fi
assert_contains "$bad_profile_output" 'unsupported OpenClaw profile'

cat >"$fixture/bad-policy.json" <<'EOF'
{
  "version": "2026.9.2",
  "profile_id": "openclaw-memory-core-2026.9.2",
  "scope": "project",
  "external_observation": true,
  "canonical_write": true,
  "reciprocal_write": false,
  "entries": []
}
EOF
if bad_policy_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw inspect "$project_id" "$fixture/bad-policy.json" 2>&1
)"; then
  fail "invalid OpenClaw read-only policy unexpectedly passed"
fi
assert_contains "$bad_policy_output" 'invalid canonical_write policy flag'

python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from lib.replication import LaneError, normalise_openclaw

base = {
    "version": "2026.9.2",
    "profile_id": "openclaw-memory-core-2026.9.2",
    "scope": "project",
    "external_observation": True,
    "canonical_write": False,
    "reciprocal_write": False,
    "entries": [],
}
conflicting = dict(base, principal="alice", agent_id="bob")
try:
    normalise_openclaw(conflicting, Path("/tmp"))
except LaneError as exc:
    assert "aliases are inconsistent" in str(exc)
else:
    raise AssertionError("conflicting profile aliases unexpectedly passed")
missing_policy = {key: value for key, value in base.items() if key not in {"external_observation", "canonical_write", "reciprocal_write"}}
try:
    normalise_openclaw(missing_policy, Path("/tmp"))
except LaneError as exc:
    assert "missing external_observation policy flag" in str(exc)
else:
    raise AssertionError("profile without policy flags unexpectedly passed")
oversized = dict(base, entries=[{"path": "memory/inline.md", "content": "x" * (10 * 1024 * 1024 + 1)}])
try:
    normalise_openclaw(oversized, Path("/tmp"))
except LaneError as exc:
    assert "exceeds 10 MiB bound" in str(exc)
else:
    raise AssertionError("oversized inline OpenClaw content unexpectedly passed")
PY

inspect_path="$fixture/inspect.json"
inspect_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw inspect "$project_id" "$profile_root" --output "$inspect_path"
)"
printf '%s\n' "$inspect_output" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "ok"
assert value["adapter"] == "openclaw"
assert value["profile_id"] == "openclaw-memory-core-2026.9.2"
assert value["openclaw_version"] == "2026.9.2"
assert value["canonical_write"] is False
assert value["reciprocal_write"] is False
assert value["external_observation"] is True
assert [item["path"] for item in value["entries"]] == ["memory/note.md"]
' || fail "OpenClaw inspect result was not valid"
assert_file "$inspect_path"
cmp "$inspect_path" <(printf '%s\n' "$inspect_output") || fail "OpenClaw inspect output file was not deterministic"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before" ] || fail "inspect mutated canonical OKF"

stage_dir="$fixture/openclaw-stage"
stage_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$stage_dir"
)"
printf '%s\n' "$stage_output" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "staged"
assert value["adapter"] == "openclaw"
assert value["profile_id"] == "openclaw-memory-core-2026.9.2"
assert value["entries"] == 1
assert value["canonical_write"] is False
assert value["reciprocal_write"] is False
assert value["external_observation"] is True
' || fail "OpenClaw stage result was not valid"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before" ] || fail "OpenClaw stage mutated canonical OKF"
assert_file "$stage_dir/manifest.json"
assert_file "$stage_dir/stage.json"
assert_file "$stage_dir/observations/memory/note.md"
python3 - "$stage_dir/manifest.json" "$stage_dir/stage.json" "$stage_dir/observations/memory/note.md" "$profile_root/memory/note.md" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest_path, stage_path, staged_note, source_note = sys.argv[1:]
manifest_bytes = Path(manifest_path).read_bytes()
manifest = json.loads(manifest_bytes.decode("utf-8"))
stage = json.loads(Path(stage_path).read_text(encoding="utf-8"))
entry = manifest["entries"][0]
payload = Path(staged_note).read_bytes()
assert manifest["format"] == "llm-brain-openclaw-stage.v1"
assert manifest["canonical_write"] is False
assert manifest["reciprocal_write"] is False
assert manifest["external_observation"] is True
assert entry["path"] == "memory/note.md"
assert entry["bytes"] == len(payload)
assert entry["sha256"] == hashlib.sha256(payload).hexdigest()
assert payload == Path(source_note).read_bytes()
assert stage["format"] == "llm-brain-external-observation-stage.v1"
assert stage["canonical_write"] is False
assert stage["reciprocal_write"] is False
assert stage["external_observation"] is True
assert stage["manifest_sha256"] == hashlib.sha256(manifest_bytes).hexdigest()
PY

idempotent_stage="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$stage_dir"
)"
printf '%s\n' "$idempotent_stage" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "idempotent"
assert value["canonical_write"] is False
assert value["reciprocal_write"] is False
' || fail "repeated OpenClaw stage was not idempotent"

cp "$stage_dir/observations/memory/note.md" "$fixture/openclaw-staged-copy.md"
rm "$stage_dir/observations/memory/note.md"
ln -s "$fixture/openclaw-staged-copy.md" "$stage_dir/observations/memory/note.md"
if symlink_stage_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$stage_dir" 2>&1
)"; then
  fail "symlinked OpenClaw stage unexpectedly passed"
fi
assert_contains "$symlink_stage_output" 'contains a symlink'

extra_stage_dir="$fixture/openclaw-stage-extra"
LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$extra_stage_dir" >/dev/null
printf 'unmanifested\n' >"$extra_stage_dir/unmanifested.txt"
if extra_stage_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$extra_stage_dir" 2>&1
)"; then
  fail "unmanifested OpenClaw stage artefact unexpectedly passed"
fi
assert_contains "$extra_stage_output" 'unmanifested artefacts'

inside_path="$project_dir/okf/openclaw-stage"
if inside_output="$(
  LLM_BRAIN_EXPERIMENT_OPENCLAW=1 "$cli" --root "$vault" adapters openclaw stage "$project_id" "$profile_root" --output "$inside_path" 2>&1
)"; then
  fail "OpenClaw stage inside canonical OKF unexpectedly passed"
fi
assert_contains "$inside_output" 'may not be inside canonical okf/'
[ ! -e "$inside_path" ] || fail "rejected canonical OpenClaw stage output was created"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before" ] || fail "rejected OpenClaw stage mutated canonical OKF"

printf 'OpenClaw adapter self-check: ok\n'
