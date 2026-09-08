#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$repo_root/bin/llm-brain"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-replication.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() {
  printf 'replication self-check: %s\n' "$*" >&2
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
project_id="proj_replication_self_check"
mkdir -p "$workspace" "$vault"
git -C "$workspace" init -q
git -C "$workspace" remote add origin https://example.invalid/llm-brain-replication.git
"$cli" --root "$vault" project ensure "$workspace" --id "$project_id" >/dev/null

project_dir="$vault/projects/$project_id"
mkdir -p "$project_dir/okf/claims" "$project_dir/review"

cat >"$project_dir/okf/claims/public.md" <<EOF
---
type: Claim
title: Public visible memory
brain_project_id: $project_id
brain_claim_id: public-visible
brain_review_state: approved
brain_sensitivity: internal
brain_schema_version: 3
---
# Public visible memory

Safe synthetic project-visible replication content.
EOF

cat >"$project_dir/okf/claims/alice.md" <<EOF
---
type: Claim
title: Alice visible memory
brain_project_id: $project_id
brain_claim_id: alice-visible
brain_review_state: approved
brain_sensitivity: internal
brain_principal: alice
brain_schema_version: 3
---
# Alice visible memory

Safe synthetic replication content.
EOF

cat >"$project_dir/okf/claims/bob.md" <<EOF
---
type: Claim
title: Bob visible memory
brain_project_id: $project_id
brain_claim_id: bob-visible
brain_review_state: approved
brain_sensitivity: internal
brain_principal: bob
brain_schema_version: 3
---
# Bob visible memory

Safe synthetic principal-scoped content.
EOF

cat >"$project_dir/okf/claims/restricted.md" <<EOF
---
type: Claim
title: Restricted memory
brain_project_id: $project_id
brain_claim_id: restricted-memory
brain_review_state: approved
brain_sensitivity: restricted
brain_schema_version: 3
---
# Restricted memory

This synthetic record must not leave the vault.
EOF

cat >"$project_dir/okf/claims/secret.md" <<EOF
---
type: Claim
title: Secret-looking memory
brain_project_id: $project_id
brain_claim_id: secret-memory
brain_review_state: approved
brain_sensitivity: internal
brain_schema_version: 3
---
# Secret-looking memory

api_key: "ABCDEFGHIJKLMNOP"
EOF

cat >"$project_dir/okf/claims/mismatched.md" <<EOF
---
type: Claim
title: Other project memory
brain_project_id: proj_other_project
brain_claim_id: other-project-memory
brain_review_state: approved
brain_sensitivity: internal
brain_schema_version: 3
---
# Other project memory

This synthetic record belongs to another project.
EOF

cat >"$project_dir/review/alice.md" <<EOF
---
type: ReviewItem
title: Alice replication review
brain_project_id: $project_id
brain_review_state: approved
brain_sensitivity: internal
brain_principal: alice
brain_schema_version: 3
---
# Alice replication review

Synthetic review binding for principal export.
EOF

canonical_before_export="$(tree_digest "$project_dir/okf")"
project_archive="$fixture/project-one.tar.gz"
project_export="$("$cli" --root "$vault" export replication "$project_id" --output "$project_archive")"
printf '%s\n' "$project_export" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "ok"
assert value["operation"] == "export"
assert value["scope"] == "project"
assert value["canonical_write"] is False
assert value["entries"] >= 2
assert value["excluded"] >= 3
' || fail "project export result was not valid"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before_export" ] || fail "export mutated canonical OKF"

assert_file "$project_archive"
assert_file "$project_archive.manifest.json"
assert_file "$project_archive.sha256"
python3 - "$project_archive" "$project_archive.manifest.json" "$project_archive.sha256" <<'PY'
import hashlib
import json
import sys
import tarfile

archive, manifest_sidecar, hash_sidecar = sys.argv[1:]
actual_hash = hashlib.sha256(open(archive, "rb").read()).hexdigest()
assert open(hash_sidecar, encoding="utf-8").read().split()[0] == actual_hash
manifest = json.load(open(manifest_sidecar, encoding="utf-8"))
paths = [item["path"] for item in manifest["entries"]]
assert paths == sorted(paths)
assert "okf/claims/public.md" in paths
assert "okf/claims/alice.md" not in paths
assert "okf/claims/bob.md" not in paths
assert "okf/claims/restricted.md" not in paths
assert "okf/claims/secret.md" not in paths
assert "okf/claims/mismatched.md" not in paths
reasons = [item["reason"] for item in manifest["excluded"]]
assert reasons.count("sensitivity-restricted") == 1
assert reasons.count("secret-scan") == 1
assert reasons.count("project-mismatch") == 1
assert reasons.count("visibility-scope") == 1
with tarfile.open(archive, "r:gz") as bundle:
    member_names = [member.name for member in bundle.getmembers()]
assert member_names == ["manifest.json"] + paths
PY

project_archive_copy="$fixture/project-two.tar.gz"
"$cli" --root "$vault" export replication "$project_id" --output "$project_archive_copy" >/dev/null
cmp "$project_archive" "$project_archive_copy" || fail "replication archive was not deterministic"
cmp "$project_archive.manifest.json" "$project_archive_copy.manifest.json" || fail "replication manifest was not deterministic"

canonical_before_import="$(tree_digest "$project_dir/okf")"
dry_run="$("$cli" --root "$vault" import replication "$project_archive" --dry-run --project-id "$project_id")"
printf '%s\n' "$dry_run" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "dry-run"
assert value["canonical_write"] is False
assert value["external_observation"] is True
' || fail "replication dry-run result was not valid"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before_import" ] || fail "dry-run mutated canonical OKF"

python3 - "$repo_root" <<'PY' || exit 1
import sys
sys.path.insert(0, sys.argv[1])
from lib.replication import LaneError, validate_manifest

manifest = {
    "format": "llm-brain-replication.v1", "manifest_version": 1,
    "schema_version": 3, "okf_version": "0.2", "project_id": "proj_test",
    "scope": [], "referenced_custody_only": True, "external_observation": True,
    "canonical_write": False, "reciprocal_write": False, "entries": [],
}
try:
    validate_manifest(manifest)
except LaneError as exc:
    assert str(exc) == "invalid replication scope"
else:
    raise AssertionError("malformed manifest scope unexpectedly passed")

manifest["scope"] = "project"
manifest["entries"] = [{"path": "okf/x.md", "sha256": "0" * 64, "bytes": 0, "kind": []}]
try:
    validate_manifest(manifest)
except LaneError as exc:
    assert str(exc) == "invalid replication entry kind: okf/x.md"
else:
    raise AssertionError("malformed manifest kind unexpectedly passed")
PY

tampered_archive="$fixture/tampered.tar.gz"
python3 - "$project_archive" "$tampered_archive" <<'PY'
import io
import sys
import tarfile

source, target = sys.argv[1:]
changed = False
with tarfile.open(source, "r:gz") as source_bundle, tarfile.open(target, "w:gz") as target_bundle:
    for member in source_bundle.getmembers():
        payload = source_bundle.extractfile(member).read()
        if member.name == "okf/claims/public.md":
            payload = payload.replace(b"Safe synthetic project-visible replication content.", b"Tampered synthetic replication content.")
            changed = True
            member.size = len(payload)
        target_bundle.addfile(member, io.BytesIO(payload))
assert changed
PY
if tamper_output="$("$cli" --root "$vault" import replication "$tampered_archive" --dry-run --project-id "$project_id" 2>&1)"; then
  fail "tampered replication payload unexpectedly passed"
fi
assert_contains "$tamper_output" 'hash mismatch'
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before_import" ] || fail "tampered import mutated canonical OKF"

stage_dir="$fixture/replication-stage"
stage_result="$("$cli" --root "$vault" import replication "$project_archive" --stage --project-id "$project_id" --output "$stage_dir")"
printf '%s\n' "$stage_result" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "staged"
assert value["canonical_write"] is False
assert value["external_observation"] is True
assert value["output"].endswith("replication-stage")
' || fail "replication stage result was not valid"
[ "$(tree_digest "$project_dir/okf")" = "$canonical_before_import" ] || fail "stage mutated canonical OKF"
assert_file "$stage_dir/manifest.json"
assert_file "$stage_dir/stage.json"
assert_file "$stage_dir/observations/okf/claims/public.md"
python3 - "$stage_dir/manifest.json" "$stage_dir/stage.json" "$stage_dir/observations" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest_path, stage_path, observations = sys.argv[1:]
manifest_bytes = Path(manifest_path).read_bytes()
manifest = json.loads(manifest_bytes.decode("utf-8"))
stage = json.loads(Path(stage_path).read_text(encoding="utf-8"))
assert manifest["canonical_write"] is False
assert manifest["external_observation"] is True
assert stage["canonical_write"] is False
assert stage["reciprocal_write"] is False
assert stage["manifest_sha256"] == hashlib.sha256(manifest_bytes).hexdigest()
assert (Path(observations) / "okf/claims/restricted.md").exists() is False
assert (Path(observations) / "okf/claims/secret.md").exists() is False
PY

idempotent_stage="$("$cli" --root "$vault" import replication "$project_archive" --stage --project-id "$project_id" --output "$stage_dir")"
printf '%s\n' "$idempotent_stage" | python3 -c '
import json
import sys

assert json.load(sys.stdin)["status"] == "idempotent"
' || fail "repeated replication stage was not idempotent"

cp "$stage_dir/observations/okf/claims/public.md" "$fixture/staged-copy.md"
rm "$stage_dir/observations/okf/claims/public.md"
ln -s "$fixture/staged-copy.md" "$stage_dir/observations/okf/claims/public.md"
if symlink_stage_output="$($cli --root "$vault" import replication "$project_archive" --stage --project-id "$project_id" --output "$stage_dir" 2>&1)"; then
  fail "symlinked replication stage unexpectedly passed"
fi
assert_contains "$symlink_stage_output" 'contains a symlink'

extra_stage_dir="$fixture/replication-stage-extra"
"$cli" --root "$vault" import replication "$project_archive" --stage --project-id "$project_id" --output "$extra_stage_dir" >/dev/null
printf 'unmanifested\n' >"$extra_stage_dir/unmanifested.txt"
if extra_stage_output="$($cli --root "$vault" import replication "$project_archive" --stage --project-id "$project_id" --output "$extra_stage_dir" 2>&1)"; then
  fail "unmanifested replication stage artefact unexpectedly passed"
fi
assert_contains "$extra_stage_output" 'unmanifested artefacts'

inside_stage="$project_dir/okf/replication-stage-without-project-id"
if no_context_output="$($cli --root "$vault" import replication "$project_archive" --stage --output "$inside_stage" 2>&1)"; then
  fail "replication stage without project context unexpectedly passed"
fi
assert_contains "$no_context_output" 'requires --project-id for canonical protection'
[ ! -e "$inside_stage" ] || fail "no-context replication stage created output"

foreign_scope_archive="$fixture/foreign-scope.tar.gz"
python3 - "$repo_root" "$foreign_scope_archive" "$project_id" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from lib.replication import sha256_bytes, write_archive

archive = Path(sys.argv[2])
project_id = sys.argv[3]
data = ("---\nbrain_project_id: %s\nbrain_principal: bob\nbrain_sensitivity: internal\n---\nBob-only record\n" % project_id).encode()
path = "okf/claims/bob.md"
manifest = {
    "format": "llm-brain-replication.v1", "manifest_version": 1,
    "schema_version": 3, "okf_version": "0.2", "project_id": project_id,
    "scope": "project", "principal": None, "review_ref": None,
    "review_hash_sha256": None, "referenced_custody_only": True,
    "external_observation": True, "canonical_write": False,
    "reciprocal_write": False,
    "entries": [{"path": path, "sha256": sha256_bytes(data), "bytes": len(data),
                  "kind": "canonical", "sensitivity": "internal"}],
}
write_archive(archive, manifest, {path: data})
PY
if foreign_scope_output="$($cli --root "$vault" import replication "$foreign_scope_archive" --stage --project-id "$project_id" --output "$fixture/foreign-scope-stage" 2>&1)"; then
  fail "foreign-scope replication archive unexpectedly passed"
fi
assert_contains "$foreign_scope_output" 'outside manifest scope'

missing_review_archive="$fixture/missing-review.tar.gz"
python3 - "$repo_root" "$missing_review_archive" "$project_id" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from lib.replication import sha256_bytes, write_archive

archive = Path(sys.argv[2])
project_id = sys.argv[3]
data = b"unscoped observation\n"
path = "okf/claims/public.md"
manifest = {
    "format": "llm-brain-replication.v1", "manifest_version": 1,
    "schema_version": 3, "okf_version": "0.2", "project_id": project_id,
    "scope": "principal", "principal": "alice", "review_ref": "review/alice.md",
    "review_hash_sha256": sha256_bytes(data), "referenced_custody_only": True,
    "external_observation": True, "canonical_write": False,
    "reciprocal_write": False,
    "entries": [{"path": path, "sha256": sha256_bytes(data), "bytes": len(data),
                  "kind": "canonical", "sensitivity": "internal"}],
}
write_archive(archive, manifest, {path: data})
PY
if missing_review_output="$($cli --root "$vault" import replication "$missing_review_archive" --stage --project-id "$project_id" --output "$fixture/missing-review-stage" 2>&1)"; then
  fail "principal archive without review unexpectedly passed"
fi
assert_contains "$missing_review_output" 'review entry is missing'

stale_sidecar_archive="$fixture/stale-sidecar.tar.gz"
python3 - "$repo_root" "$project_archive" "$stale_sidecar_archive" <<'PY'
import io
import json
import sys
import tarfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from lib.replication import canonical_json, sha256_bytes, tar_info

source, target = map(Path, sys.argv[2:])
with tarfile.open(source, "r:gz") as bundle:
    members = {member.name: bundle.extractfile(member).read() for member in bundle.getmembers()}
manifest = json.loads(members.pop("manifest.json").decode("utf-8"))
path = "okf/claims/public.md"
changed = members[path].replace(b"Safe synthetic project-visible replication content.", b"Consistently rewritten content.")
members[path] = changed
for item in manifest["entries"]:
    if item["path"] == path:
        item["sha256"] = sha256_bytes(changed)
        item["bytes"] = len(changed)
manifest_bytes = canonical_json(manifest)
with tarfile.open(target, "w:gz") as bundle:
    bundle.addfile(tar_info("manifest.json", manifest_bytes), io.BytesIO(manifest_bytes))
    for name in sorted(members):
        bundle.addfile(tar_info(name, members[name]), io.BytesIO(members[name]))
old_hash = source.with_name(source.name + ".sha256").read_text(encoding="utf-8").split()[0]
target.with_name(target.name + ".sha256").write_text(old_hash + "  " + target.name + "\n", encoding="utf-8")
PY
if stale_sidecar_output="$($cli --root "$vault" import replication "$stale_sidecar_archive" --dry-run --project-id "$project_id" 2>&1)"; then
  fail "archive with stale custody sidecar unexpectedly passed"
fi
assert_contains "$stale_sidecar_output" 'custody sidecar hash/name mismatch'

cp "$project_dir/review/alice.md" "$fixture/review-target.md"
ln -s "$fixture/review-target.md" "$project_dir/review/alice-link.md"
if symlink_review_output="$($cli --root "$vault" export replication "$project_id" --scope principal --principal alice --review review/alice-link.md --output "$fixture/symlink-review.tar.gz" 2>&1)"; then
  fail "symlinked principal review unexpectedly passed"
fi
assert_contains "$symlink_review_output" 'review reference is missing'

principal_archive="$fixture/principal-alice.tar.gz"
principal_export="$("$cli" --root "$vault" export replication "$project_id" --scope principal --principal alice --review review/alice.md --output "$principal_archive")"
printf '%s\n' "$principal_export" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
assert value["status"] == "ok"
assert value["scope"] == "principal"
assert value["canonical_write"] is False
' || fail "principal export result was not valid"
python3 - "$principal_archive.manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
paths = {item["path"] for item in manifest["entries"]}
assert manifest["scope"] == "principal"
assert manifest["principal"] == "alice"
assert manifest["review_ref"] == "review/alice.md"
assert "okf/claims/alice.md" in paths
assert "okf/claims/bob.md" not in paths
assert "review/alice.md" in paths
assert any(item["reason"] == "visibility-scope" for item in manifest["excluded"])
PY

printf 'replication self-check: ok\n'
