#!/usr/bin/env bash
# Build-only helper. Python is intentionally not a runtime dependency.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_name="llm-brain"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
requested_version="${1:-$version}"

[ "$requested_version" = "$version" ] || { printf 'package: VERSION is authoritative (%s)\n' "$version" >&2; exit 64; }
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) printf 'package: invalid SemVer in VERSION\n' >&2; exit 65 ;; esac

bash -n "$repo_root/bin/llm-brain"
bash -n "$repo_root/tests/self-check.sh"
bash -n "$repo_root/tests/v2-self-check.sh"

dist_dir="$repo_root/dist"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-package.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
skill_stage="$stage_root/skill/$package_name"

mkdir -p \
  "$skill_stage/references" \
  "$skill_stage/scripts"

install -m 0644 "$repo_root/LICENSE" "$skill_stage/LICENSE"
install -m 0644 "$repo_root/VERSION" "$skill_stage/VERSION"
install -m 0644 "$repo_root/SKILL.md" "$skill_stage/SKILL.md"
install -m 0644 "$repo_root/references/architecture.md" "$skill_stage/references/architecture.md"
install -m 0755 "$repo_root/bin/llm-brain" "$skill_stage/scripts/llm-brain"

bash -n "$skill_stage/scripts/llm-brain"

mkdir -p "$dist_dir"
python3 - "$stage_root" "$dist_dir" "$package_name" "$version" <<'PY'
import gzip
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

stage_root = Path(sys.argv[1])
dist_dir = Path(sys.argv[2])
name = sys.argv[3]
version = sys.argv[4]

def members(root: Path):
    entries = [root]
    entries.extend(sorted(root.rglob("*"), key=lambda p: p.relative_to(root.parent).as_posix()))
    return entries

def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts and name and not name.startswith("./")

def build(root: Path, destination: Path):
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            with tarfile.open(mode="w", fileobj=zipped, format=tarfile.PAX_FORMAT) as archive:
                for source in members(root):
                    arcname = source.relative_to(root.parent).as_posix()
                    if not safe_member(arcname):
                        raise ValueError(f"unsafe archive member: {arcname}")
                    info = archive.gettarinfo(str(source), arcname)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    if info.isfile():
                        info.mode = 0o755 if os.access(source, os.X_OK) else 0o644
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)
                    elif info.isdir():
                        info.mode = 0o755
                        archive.addfile(info)
                    else:
                        raise ValueError(f"unexpected archive member type: {source}")

def verify(archive_path: Path, expected_root: str, cli_member: str):
    with tarfile.open(archive_path, "r:gz") as archive:
        names = archive.getnames()
        if not names or any(not safe_member(item) for item in names):
            raise ValueError("unsafe archive layout")
        if any(not (item == expected_root or item.startswith(expected_root + "/")) for item in names):
            raise ValueError("unexpected archive root")
        required = {f"{expected_root}/LICENSE", f"{expected_root}/VERSION", cli_member}
        if not required.issubset(names):
            raise ValueError("archive misses required release files")
        with tempfile.TemporaryDirectory(prefix="llm-brain-verify-") as temp:
            archive.extractall(temp)
            extracted = Path(temp) / expected_root / cli_member.removeprefix(expected_root + "/")
            if not extracted.is_file():
                raise ValueError("packaged CLI missing after extraction")
            os.chmod(extracted, 0o755)
            observed = subprocess.check_output([str(extracted), "--version"], text=True).strip()
            if observed != version:
                raise ValueError(f"packaged CLI version mismatch: {observed}")
            subprocess.run([str(extracted), "help"], check=True, stdout=subprocess.DEVNULL)

targets = [
    (stage_root / "skill" / name, dist_dir / f"{name}-{version}.tar.gz", f"{name}/scripts/llm-brain"),
]
for root, destination, cli_member in targets:
    first = destination.with_suffix(destination.suffix + ".first")
    second = destination.with_suffix(destination.suffix + ".second")
    build(root, first)
    build(root, second)
    if first.read_bytes() != second.read_bytes():
        raise ValueError(f"non-reproducible archive: {destination.name}")
    first.replace(destination)
    second.unlink()
    verify(destination, name, cli_member)
    digest = __import__("hashlib").sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(destination.suffix + ".sha256").write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
PY

printf 'package=ok type=standalone file=%s\n' "$dist_dir/${package_name}-${version}.tar.gz"
