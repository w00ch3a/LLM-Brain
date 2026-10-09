#!/usr/bin/env python3
"""Build the self-contained real-eval bundle (deterministic .tgz).

    python3 evals/real/build_bundle.py --archive dist/llm-brain-0.8.0-standalone.tar.gz \
        --pyyaml-sdist pyyaml-6.0.3.tar.gz --output /path/llm-brain-real-eval.tgz

The PyYAML sdist must match the hash pinned in requirements-okf.lock; only its
pure-Python ``yaml`` package and licence are vendored.
"""

import argparse
import gzip
import hashlib
import io
import re
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
TOP = "llm-brain-real-eval"
FILES = ["run.sh", "README.md", "eval_real.py", "reference_agent.py", "tasks/coding.py", "tasks/research.py"]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--pyyaml-sdist", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    archive = Path(args.archive)
    expected = Path(str(archive) + ".sha256").read_text().split()[0]
    archive_bytes = archive.read_bytes()
    if sha256(archive_bytes) != expected:
        raise SystemExit("standalone archive checksum mismatch")
    lock = (REPO / "requirements-okf.lock").read_text()
    pinned = re.search(r"PyYAML==([\d.]+).*?--hash=sha256:([0-9a-f]{64})", lock, re.S)
    sdist = Path(args.pyyaml_sdist).read_bytes()
    if not pinned or sha256(sdist) != pinned.group(2):
        raise SystemExit("PyYAML sdist does not match requirements-okf.lock")
    entries: dict[str, tuple[bytes, int]] = {}
    for rel in FILES:
        entries[rel] = ((HERE / rel).read_bytes(), 0o755 if rel.endswith((".sh", "eval_real.py", "reference_agent.py")) else 0o644)
    entries[f"dist/{archive.name}"] = (archive_bytes, 0o644)
    entries[f"dist/{archive.name}.sha256"] = (f"{expected}  {archive.name}\n".encode(), 0o644)
    with tarfile.open(fileobj=io.BytesIO(sdist), mode="r:gz") as tar:
        for member in tar.getmembers():
            parts = member.name.split("/")
            if len(parts) >= 3 and parts[1] == "lib" and parts[2] == "yaml" and member.isfile() and member.name.endswith(".py"):
                entries["vendor/yaml/" + "/".join(parts[3:])] = (tar.extractfile(member).read(), 0o644)
            elif len(parts) == 2 and parts[1] == "LICENSE":
                entries["vendor/PyYAML-LICENSE"] = (tar.extractfile(member).read(), 0o644)
    if "vendor/yaml/__init__.py" not in entries:
        raise SystemExit("sdist has no lib/yaml package")
    manifest = "".join(f"{sha256(data)}  {rel}\n" for rel, (data, _) in sorted(entries.items()))
    entries["MANIFEST.sha256"] = (manifest.encode(), 0o644)
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        dirs = sorted({"/".join(rel.split("/")[:i]) for rel in entries for i in range(1, rel.count("/") + 1)})
        for d in [""] + dirs:
            info = tarfile.TarInfo(f"{TOP}/{d}".rstrip("/"))
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, 0
            tar.addfile(info)
        for rel, (data, mode) in sorted(entries.items()):
            info = tarfile.TarInfo(f"{TOP}/{rel}")
            info.size, info.mode, info.mtime = len(data), mode, 0
            tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(out.getvalue())
    Path(args.output + ".sha256").write_text(f"{sha256(out.getvalue())}  {Path(args.output).name}\n")
    print(f"bundle=ok file={args.output} sha256={sha256(out.getvalue())} files={len(entries)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
