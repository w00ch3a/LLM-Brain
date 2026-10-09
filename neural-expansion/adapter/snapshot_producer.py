#!/usr/bin/env python3
"""Package one actual-format v0.7.5 index generation for the local viewer.

The producer is read-only against its source tree. It stages a bounded snapshot
in a new destination directory; it never edits the source index or OKF records.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path, PurePosixPath

from export_graph import (
    DOC_HEADER,
    ExportError,
    GENERATION_RE,
    MANIFEST_HEADER,
    _digest,
    _open_directory,
    _read_at,
    _safe_rel,
    _tsv,
)


def build_snapshot(source: Path, destination: Path) -> Path:
    """Copy one pointer-selected generation and verified source/retraction files."""
    source_fd = _open_directory(source)
    try:
        source_root = [0]
        pointer = _read_at(source_fd, "indexes/current", source_root)
        try:
            generation = pointer.decode("ascii").strip()
        except UnicodeDecodeError as exc:
            raise ExportError("invalid source index") from exc
        if not GENERATION_RE.fullmatch(generation):
            raise ExportError("invalid source index")
        generation_prefix = f"indexes/generations/{generation}/"
        source_assets: dict[str, bytes] = {}
        for name in ("documents.tsv", "graph.tsv", "manifest.tsv"):
            relative = generation_prefix + name
            raw = _read_at(source_fd, relative, source_root)
            source_assets[name] = raw
        docs = _tsv(source_assets["documents.tsv"], DOC_HEADER, 15)
        graph = _tsv(source_assets["graph.tsv"], "source\trelation\ttarget", 3)
        manifest = _tsv(source_assets["manifest.tsv"], MANIFEST_HEADER, 4)
        doc_hashes: dict[str, str] = {}
        for row in docs:
            rel = _safe_rel(row[0])
            if not rel.startswith("okf/") or not rel.endswith(".md") or rel in doc_hashes:
                raise ExportError("invalid source index")
            if not re.fullmatch(r"[0-9a-f]{64}", row[1]):
                raise ExportError("invalid source index")
            doc_hashes[rel] = row[1]
        manifest_hashes: dict[str, str] = {}
        for row in manifest:
            rel = _safe_rel(row[0])
            if not rel.startswith("okf/") or not rel.endswith(".md") or rel in manifest_hashes:
                raise ExportError("invalid source index")
            if not re.fullmatch(r"[0-9a-f]{64}", row[1]):
                raise ExportError("invalid source index")
            manifest_hashes[rel] = row[1]
        if doc_hashes != manifest_hashes:
            raise ExportError("stale source index")

        copies: dict[str, bytes] = dict(source_assets)
        retraction_inputs: dict[str, bytes | None] = {}
        for rel, expected in doc_hashes.items():
            raw = _read_at(source_fd, rel, source_root)
            if _digest(raw) != expected:
                raise ExportError("stale source index")
            copies["documents/" + rel] = raw
            retraction_rel = f"okf/retractions/{PurePosixPath(rel).stem}.md"
            tombstone = _read_at(source_fd, retraction_rel, source_root, optional=True)
            previous = retraction_inputs.get(retraction_rel, tombstone)
            if previous != tombstone:
                raise ExportError("stale source index")
            retraction_inputs[retraction_rel] = tombstone
            if tombstone is not None:
                copies["documents/" + retraction_rel] = tombstone

        # The pointer-selected generation is immutable by contract. Recheck all
        # copied inputs by descriptor before publication to catch concurrent
        # source changes, especially the unindexed retraction tombstones.
        confirm_total = [0]
        for name, original in source_assets.items():
            confirm = _read_at(source_fd, generation_prefix + name, confirm_total)
            if confirm != original:
                raise ExportError("stale source index")
        for rel, expected in doc_hashes.items():
            confirm = _read_at(source_fd, rel, confirm_total)
            if _digest(confirm) != expected or confirm != copies["documents/" + rel]:
                raise ExportError("stale source index")
        # Parse relation rows already to reject malformed TSV; unresolved opaque
        # refs are retained as-is and safely removed by the principal-filtered
        # projection step.
        if any(not source_ref or not relation or not target for source_ref, relation, target in graph):
            raise ExportError("invalid source index")

        source_real = Path(os.path.realpath(source))
        destination = Path(os.path.abspath(destination))
        destination_real = Path(os.path.realpath(destination))
        parent = destination.parent
        try:
            destination_real.relative_to(source_real)
            contained = True
        except ValueError:
            contained = False
        if contained:
            raise ExportError("destination must be outside source tree")
        if destination.exists() or destination.is_symlink() or not parent.is_dir():
            raise ExportError("destination must be a new directory")
        stage = Path(tempfile.mkdtemp(prefix=".llm-brain-viewer-", dir=parent))
        try:
            gen_dir = stage / "indexes" / "generations" / generation
            gen_dir.mkdir(parents=True)
            for name, raw in source_assets.items():
                (gen_dir / name).write_bytes(raw)
            files = {}
            for name, raw in source_assets.items():
                files[name] = _digest(raw)
            for relative, raw in copies.items():
                if relative in source_assets:
                    continue
                target = gen_dir / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
                files[relative] = _digest(raw)
            (gen_dir / "snapshot.json").write_text(
                json.dumps({"generation": generation, "files": files}, sort_keys=True, separators=(",", ":")),
                encoding="utf-8",
            )
            (stage / "indexes" / "current").write_text(generation + "\n", encoding="ascii")
            # Recheck presence as well as content immediately before publication.
            # This pins the observed tombstone state; it does not claim the source
            # tree remains current after this snapshot is published.
            final_check_total = [0]
            for rel, original in retraction_inputs.items():
                current = _read_at(source_fd, rel, final_check_total, optional=True)
                if current != original:
                    raise ExportError("stale source index")
            os.rename(stage, destination)
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise
        return destination
    finally:
        os.close(source_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="read-only project snapshot with indexes/current")
    parser.add_argument("destination", type=Path, help="new local package directory")
    args = parser.parse_args()
    try:
        result = build_snapshot(args.source, args.destination)
    except ExportError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
