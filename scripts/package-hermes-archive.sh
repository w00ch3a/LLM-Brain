#!/usr/bin/env bash
# Build the reproducible Hermes plugin release archive:
#   dist/llm-brain-VERSION-hermes.tar.gz and its .sha256
# The archive holds one llm-brain/ directory, ready to copy into
# "$HERMES_HOME/plugins/". Members have fixed owners, modes and timestamps.
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
dist="${1:-$repo_root/dist}"
mkdir -p "$dist"
work="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-hermes-archive.XXXXXX")"
trap 'rm -rf "$work"' EXIT

bash "$script_dir/package-hermes-plugin.sh" "$work/stage/llm-brain" >/dev/null

python3 - "$work/stage/llm-brain" "$dist/llm-brain-${version}-hermes.tar.gz" "$version" <<'PY'
import gzip
import hashlib
import sys
import tarfile
from pathlib import Path

root, destination, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]


def members(base: Path):
    yield base
    for path in sorted(base.rglob("*"), key=lambda item: item.relative_to(base).as_posix()):
        if path.name == "__pycache__" or path.suffix in {".pyc", ".pyo"} or path.name == ".DS_Store":
            continue
        if "__pycache__" in path.parts:
            continue
        yield path


def build(target: Path) -> None:
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            with tarfile.open(mode="w", fileobj=zipped, format=tarfile.PAX_FORMAT) as archive:
                for source in members(root):
                    arcname = source.relative_to(root.parent).as_posix()
                    if arcname.startswith("/") or ".." in arcname.split("/"):
                        raise SystemExit(f"unsafe archive member: {arcname}")
                    info = archive.gettarinfo(str(source), arcname)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    if info.isdir():
                        info.mode = 0o755
                        archive.addfile(info)
                    elif info.isfile():
                        info.mode = 0o644
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)
                    else:
                        raise SystemExit(f"unexpected archive member: {arcname}")


first = destination.with_name(destination.name + ".first")
second = destination.with_name(destination.name + ".second")
build(first)
build(second)
if first.read_bytes() != second.read_bytes():
    raise SystemExit("non-reproducible Hermes archive")
first.replace(destination)
second.unlink()

with tarfile.open(destination, "r:gz") as archive:
    names = set(archive.getnames())
    required = {"llm-brain/__init__.py", "llm-brain/plugin.yaml", "llm-brain/README.md",
                f"llm-brain/docs/releases/v{version}.md"}
    if not required <= names or any(not (n == "llm-brain" or n.startswith("llm-brain/")) for n in names):
        raise SystemExit("Hermes archive layout is incomplete")
    manifest = archive.extractfile("llm-brain/plugin.yaml").read().decode("utf-8")
    if f"version: {version}" not in manifest.splitlines():
        raise SystemExit("Hermes archive manifest version mismatch")
digest = hashlib.sha256(destination.read_bytes()).hexdigest()
destination.with_name(destination.name + ".sha256").write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
PY
chmod 0644 "$dist/llm-brain-${version}-hermes.tar.gz" "$dist/llm-brain-${version}-hermes.tar.gz.sha256"
printf 'package=ok type=hermes file=%s\n' "$dist/llm-brain-${version}-hermes.tar.gz"
