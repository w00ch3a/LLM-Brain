#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="llm-brain"
version="$(tr -d '[:space:]' <"$repo_root/VERSION")"
requested="${1:-$version}"
declared_yaml="$(sed -n 's/^PYYAML_VERSION="\([^"]*\)"/\1/p' "$repo_root/bin/llm-brain")"
locked_yaml="$(sed -n 's/^PyYAML==\([^[:space:]\\]*\).*/\1/p' "$repo_root/requirements-okf.lock")"

[ "$requested" = "$version" ] || { printf 'package: VERSION is authoritative (%s)\n' "$version" >&2; exit 64; }
[ -n "$declared_yaml" ] && [ "$declared_yaml" = "$locked_yaml" ] ||
  { printf 'package: PyYAML runtime and lock file disagree\n' >&2; exit 65; }
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) printf 'package: invalid SemVer in VERSION\n' >&2; exit 65 ;; esac

bash -n "$repo_root/bin/llm-brain"
bash -n "$repo_root/tests/self-check.sh"
bash -n "$repo_root/tests/okf-self-check.sh"
bash -n "$repo_root/tests/v3-self-check.sh"
bash -n "$repo_root/tests/upgrade-self-check.sh"
bash -n "$repo_root/tests/passive-self-check.sh"
bash -n "$repo_root/hooks/session-start.sh"
python3 -m py_compile "$repo_root/lib/okf.py"

python3 - "$repo_root" "$version" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
version = sys.argv[2]
for path in (
    root / ".codex-plugin/plugin.json",
    root / ".claude-plugin/plugin.json",
    root / "gemini-extension.json",
):
    observed = json.loads(path.read_text(encoding="utf-8")).get("version")
    if observed != version:
        raise SystemExit(f"package: manifest version mismatch: {path}={observed}")
PY

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/llm-brain-package.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
plugin="$stage_root/plugin/$name"
standalone="$stage_root/standalone/$name"
mkdir -p \
  "$plugin/skills/llm-brain/scripts" \
  "$plugin/skills/llm-brain/references" \
  "$standalone/bin" \
  "$standalone/lib" \
  "$standalone/adapters"

for item in LICENSE README.md SKILL.md VERSION GEMINI.md gemini-extension.json requirements-okf.lock; do
  install -m 0644 "$repo_root/$item" "$plugin/$item"
done
for directory in .codex-plugin .claude-plugin adapters hooks; do
  cp -R "$repo_root/$directory" "$plugin/$directory"
done
cp -R "$repo_root/skills/." "$plugin/skills/"
install -m 0755 "$repo_root/bin/llm-brain" "$plugin/skills/llm-brain/scripts/llm-brain"
install -m 0755 "$repo_root/lib/okf.py" "$plugin/skills/llm-brain/scripts/okf.py"
install -m 0644 "$repo_root/references/architecture.md" "$plugin/skills/llm-brain/references/architecture.md"
install -m 0644 "$repo_root/VERSION" "$plugin/skills/llm-brain/VERSION"

install -m 0644 "$repo_root/LICENSE" "$repo_root/README.md" "$repo_root/VERSION" "$repo_root/requirements-okf.lock" "$standalone/"
install -m 0755 "$repo_root/bin/llm-brain" "$standalone/bin/llm-brain"
install -m 0755 "$repo_root/lib/okf.py" "$standalone/lib/okf.py"
install -m 0644 "$repo_root/adapters/generic.md" "$standalone/adapters/generic.md"

if LC_ALL=C grep -R -nE '/Users/[^$[:space:]]+|/home/[^$[:space:]]+|(^|[^0-9])(10|127|169\.254|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+' "$plugin" "$standalone"; then
  printf 'package: private machine identifier found in public archive input\n' >&2
  exit 65
fi

dist="$repo_root/dist"
mkdir -p "$dist"
python3 - "$stage_root" "$dist" "$name" "$version" <<'PY'
import gzip
import hashlib
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

stage = Path(sys.argv[1])
dist = Path(sys.argv[2])
name = sys.argv[3]
version = sys.argv[4]


def safe_member(raw: str) -> bool:
    path = PurePosixPath(raw)
    return bool(raw) and not path.is_absolute() and ".." not in path.parts


def members(root: Path) -> list[Path]:
    return [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root.parent).as_posix())]


def build(root: Path, destination: Path) -> None:
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
                        raise ValueError(f"unexpected archive member: {arcname}")


def verify(path: Path, kind: str) -> None:
    with tarfile.open(path, "r:gz") as archive:
        names = archive.getnames()
        if not names or any(not safe_member(item) for item in names):
            raise ValueError(f"unsafe {kind} archive")
        if any(not (item == name or item.startswith(name + "/")) for item in names):
            raise ValueError(f"unexpected {kind} archive root")
        cli = (
            f"{name}/skills/llm-brain/scripts/llm-brain"
            if kind == "plugin"
            else f"{name}/bin/llm-brain"
        )
        required = {f"{name}/VERSION", cli, f"{name}/requirements-okf.lock"}
        if kind == "plugin":
            required |= {
                f"{name}/.codex-plugin/plugin.json",
                f"{name}/.claude-plugin/plugin.json",
                f"{name}/gemini-extension.json",
                f"{name}/skills/llm-brain-upgrade/SKILL.md",
            }
        if not required.issubset(names):
            raise ValueError(f"{kind} archive is incomplete")
        with tempfile.TemporaryDirectory(prefix="llm-brain-verify-") as temporary:
            archive.extractall(temporary)
            executable = Path(temporary) / cli
            executable.chmod(0o755)
            observed = subprocess.check_output([str(executable), "--version"], text=True).strip()
            if observed != version:
                raise ValueError(f"packaged CLI version mismatch: {observed}")


for kind in ("plugin", "standalone"):
    root = stage / kind / name
    destination = dist / f"{name}-{version}-{kind}.tar.gz"
    first = destination.with_suffix(destination.suffix + ".first")
    second = destination.with_suffix(destination.suffix + ".second")
    build(root, first)
    build(root, second)
    if first.read_bytes() != second.read_bytes():
        raise ValueError(f"non-reproducible archive: {destination.name}")
    first.replace(destination)
    second.unlink()
    verify(destination, kind)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(destination.suffix + ".sha256").write_text(
        f"{digest}  {destination.name}\n", encoding="utf-8"
    )
PY

printf 'package=ok type=plugin file=%s\n' "$dist/${name}-${version}-plugin.tar.gz"
printf 'package=ok type=standalone file=%s\n' "$dist/${name}-${version}-standalone.tar.gz"
