#!/usr/bin/env python3
"""Project one immutable synthetic/approved OKF index generation for the viewer.

The input is a bounded snapshot, never a vault root.  No file is written by this
adapter.  Principal filtering happens before records or relations are serialized.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

import yaml


MAX_FILE = 4 * 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024
GENERATION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
DOC_HEADER = "path\thash\ttype\ttitle\tstate\tstatus\ttrust\tfreshness\tsensitivity\ttemperature\ttopic_id\tgenerated_at\tstale_after\tsources\truntime"
MANIFEST_HEADER = "path\thash\tschema\tembedder"
VIEWER_SNAPSHOT_FORMAT = "llm-brain-viewer-snapshot.v1"
PROJECT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class ExportError(ValueError):
    """Safe, non-path-bearing adapter failure."""


class UniqueLoader(yaml.SafeLoader):
    pass


def _unique_mapping(loader: UniqueLoader, node: yaml.nodes.MappingNode, deep: bool = False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            if key in result:
                raise ExportError("invalid snapshot")
            result[key] = loader.construct_object(value_node, deep=deep)
        except TypeError as exc:
            raise ExportError("invalid snapshot") from exc
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)


def _open_directory(path: Path) -> int:
    """Open a directory by walking from / with O_NOFOLLOW at every component."""
    try:
        supplied = Path(os.path.abspath(path))
        supplied_stat = os.lstat(supplied)
        if not stat.S_ISDIR(supplied_stat.st_mode) or stat.S_ISLNK(supplied_stat.st_mode):
            raise ExportError("invalid snapshot")
        # macOS exposes temporary paths through /var -> /private/var; resolve
        # aliases first, then walk the canonical ancestors with O_NOFOLLOW.
        absolute = Path(os.path.realpath(supplied))
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in absolute.parts[1:]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            return fd
        except Exception:
            os.close(fd)
            raise
    except OSError as exc:
        raise ExportError("invalid snapshot") from exc


def _read_at(root_fd: int, relative: str, total: list[int], *, optional: bool = False) -> bytes | None:
    """Read a regular file through held directory descriptors (no path re-open race)."""
    rel = _safe_rel(relative)
    parts = rel.split("/")
    parent_fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            try:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            except FileNotFoundError:
                if optional:
                    return None
                raise
            os.close(parent_fd)
            parent_fd = next_fd
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0), dir_fd=parent_fd)
        except FileNotFoundError:
            if optional:
                return None
            raise
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE or total[0] + before.st_size > MAX_TOTAL:
                raise ExportError("invalid snapshot")
            chunks = []
            remaining = MAX_FILE + 1
            while remaining:
                chunk = os.read(fd, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            after = os.fstat(fd)
            if len(raw) > MAX_FILE or total[0] + len(raw) > MAX_TOTAL:
                raise ExportError("invalid snapshot")
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) or len(raw) != after.st_size:
                raise ExportError("stale snapshot")
            total[0] += len(raw)
            return raw
        finally:
            os.close(fd)
    except (OSError, ValueError) as exc:
        if isinstance(exc, ExportError):
            raise
        raise ExportError("invalid snapshot") from exc
    finally:
        os.close(parent_fd)


def _safe_rel(value: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise ExportError("invalid snapshot")
    p = PurePosixPath(value)
    if p.is_absolute() or p.as_posix() != value or any(part in {"", ".", ".."} for part in p.parts):
        raise ExportError("invalid snapshot")
    return p.as_posix()


def _tsv(raw: bytes, header: str, columns: int) -> list[list[str]]:
    try:
        text = raw.decode("utf-8")
        rows = list(csv.reader(io.StringIO(text, newline=""), delimiter="\t", strict=True))
    except (UnicodeDecodeError, csv.Error) as exc:
        raise ExportError("invalid snapshot") from exc
    if not rows or "\t".join(rows[0]) != header or any(len(row) != columns for row in rows[1:]):
        raise ExportError("invalid snapshot")
    return rows[1:]


def _digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _refs(value: Any) -> list[str] | None:
    if value is None:
        return []
    values = value if isinstance(value, list) else [value]
    result: list[str] = []
    for item in values:
        if not isinstance(item, str):
            return None
        comma_parts = item.split(",")
        for part in comma_parts:
            lines = part.splitlines() or [part]
            found = False
            for line in lines:
                value = line.strip()
                if value:
                    result.append(value)
                    found = True
            if not found and len(comma_parts) > 1:
                return None
    return list(dict.fromkeys(result))


def _frontmatter(raw: bytes) -> tuple[dict[str, Any], str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ExportError("invalid snapshot") from exc
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise ExportError("invalid snapshot")
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        raise ExportError("invalid snapshot")
    try:
        meta = yaml.load("".join(lines[1:end]), Loader=UniqueLoader)
    except (yaml.YAMLError, ExportError) as exc:
        raise ExportError("invalid snapshot") from exc
    if not isinstance(meta, dict) or not all(isinstance(key, str) for key in meta):
        raise ExportError("invalid snapshot")
    return meta, "".join(lines[end + 1 :])


def _visible(meta: dict[str, Any], principal: str, retracted: bool) -> bool:
    sensitivity = meta.get("brain_sensitivity", meta.get("sensitivity", "internal"))
    if sensitivity is None:
        sensitivity = "internal"
    if sensitivity != "internal" or retracted:
        return False
    scoped = _refs(meta.get("brain_principal"))
    audience = _refs(meta.get("brain_audience"))
    if scoped is None or audience is None:
        return False
    identities = scoped + audience
    if identities and principal not in identities:
        return False
    status = meta.get("status", "stable")
    review = meta.get("brain_review_state", meta.get("review_state", ""))
    if not isinstance(status, str) or not isinstance(review, str):
        return False
    if status.strip().lower() == "deprecated":
        return False
    return review.strip().lower() == "approved" if review.strip() else status.strip().lower() == "stable"


def _unique_json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ExportError("invalid snapshot")
        result[key] = value
    return result


def _build_export(root_fd: int, principal: str, expected_project_id: str | None = None) -> dict[str, Any]:
    if not principal or principal != principal.strip() or any(ord(c) < 32 for c in principal):
        raise ExportError("invalid request")
    total = [0]
    package_marker = None
    if expected_project_id is not None:
        marker_raw = _read_at(root_fd, "viewer-snapshot.json", total)
        try:
            package_marker = json.loads(marker_raw, object_pairs_hook=_unique_json_pairs)
        except (UnicodeDecodeError, json.JSONDecodeError, ExportError) as exc:
            raise ExportError("invalid snapshot") from exc
        if (
            not isinstance(package_marker, dict)
            or set(package_marker) != {"format", "version", "project_id", "generation"}
            or package_marker.get("format") != VIEWER_SNAPSHOT_FORMAT
            or type(package_marker.get("version")) is not int
            or package_marker.get("version") != 1
            or package_marker.get("project_id") != expected_project_id
            or not isinstance(package_marker.get("generation"), str)
            or not GENERATION_RE.fullmatch(package_marker["generation"])
        ):
            raise ExportError("invalid snapshot")
    pointer_raw = _read_at(root_fd, "indexes/current", total)  # Resolve exactly once per request.
    try:
        generation = pointer_raw.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise ExportError("invalid snapshot") from exc
    if not GENERATION_RE.fullmatch(generation):
        raise ExportError("invalid snapshot")
    if package_marker is not None and package_marker["generation"] != generation:
        raise ExportError("invalid snapshot")
    generation_dir = f"indexes/generations/{generation}"
    snapshot_raw = _read_at(root_fd, generation_dir + "/snapshot.json", total)
    try:
        snapshot = json.loads(snapshot_raw, object_pairs_hook=_unique_json_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError, ExportError) as exc:
        raise ExportError("invalid snapshot") from exc
    if not isinstance(snapshot, dict) or set(snapshot) != {"generation", "files"} or snapshot.get("generation") != generation or not isinstance(snapshot.get("files"), dict):
        raise ExportError("invalid snapshot")

    # Snapshot manifest binds all files to the one pointer-resolved generation.
    assets: dict[str, bytes] = {}
    for relative, expected in snapshot["files"].items():
        rel = _safe_rel(relative)
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ExportError("invalid snapshot")
        raw = _read_at(root_fd, generation_dir + "/" + rel, total)
        if _digest(raw) != expected:
            raise ExportError("stale snapshot")
        assets[rel] = raw
    required = {"documents.tsv", "graph.tsv", "manifest.tsv"}
    if not required.issubset(assets):
        raise ExportError("invalid snapshot")

    doc_rows = _tsv(assets["documents.tsv"], DOC_HEADER, 15)
    manifest_rows = _tsv(assets["manifest.tsv"], MANIFEST_HEADER, 4)
    docs: dict[str, tuple[str, list[str]]] = {}
    for row in doc_rows:
        rel = _safe_rel(row[0])
        if not rel.startswith("okf/") or not rel.endswith(".md") or rel in docs:
            raise ExportError("invalid snapshot")
        docs[rel] = (row[1], row)
    source_hashes: dict[str, str] = {}
    for row in manifest_rows:
        rel = _safe_rel(row[0])
        if not rel.startswith("okf/") or not rel.endswith(".md") or rel in source_hashes:
            raise ExportError("invalid snapshot")
        source_hashes[rel] = row[1]
    if {key: val[0] for key, val in docs.items()} != source_hashes:
        raise ExportError("stale snapshot")

    document_data: dict[str, bytes] = {}
    for rel, (indexed_hash, _) in docs.items():
        key = "documents/" + rel
        raw = assets.get(key)
        if raw is None or _digest(raw) != indexed_hash or source_hashes[rel] != indexed_hash:
            raise ExportError("stale snapshot")
        document_data[rel] = raw
    document_assets = {"documents/" + rel for rel in docs}
    tombstones = {
        key for key in assets
        if key.startswith("documents/okf/retractions/") and key.endswith(".md")
    }
    if any(".." in PurePosixPath(key).parts for key in tombstones):
        raise ExportError("invalid snapshot")
    if set(assets) != required | document_assets | tombstones:
        raise ExportError("invalid snapshot")

    records: dict[str, tuple[dict[str, Any], str]] = {}
    for rel, raw in document_data.items():
        metadata, body = _frontmatter(raw)
        stem = PurePosixPath(rel).stem
        tombstone = f"documents/okf/retractions/{stem}.md" in assets
        if _visible(metadata, principal, tombstone):
            records[rel] = (metadata, body)

    # Do not serialize, count, or label anything until the allow-set is final.
    graph_rows = _tsv(assets["graph.tsv"], "source\trelation\ttarget", 3)
    edges = []
    def canonical_endpoint(raw: str) -> str | None:
        # Relation targets are allowed to be opaque URI refs (e.g. human://).
        # Only malformed traversal/absolute local paths invalidate the snapshot.
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", raw):
            return None
        endpoint = _safe_rel(raw)
        return endpoint if endpoint.startswith("okf/") and endpoint.endswith(".md") else None

    for source, relation, target in graph_rows:
        source = canonical_endpoint(source)
        target = canonical_endpoint(target)
        if not relation or any(ord(char) < 32 for char in relation):
            raise ExportError("invalid snapshot")
        # Exact canonical paths only; unresolved/hidden endpoints disappear.
        if source is None or target is None or source not in records or target not in records:
            continue
        edges.append({"source": source, "relation": relation, "target": target})

    nodes = []
    for rel, (meta, body) in records.items():
        title = meta.get("title")
        record_type = meta.get("type")
        if not isinstance(title, str) or not title.strip() or not isinstance(record_type, str) or not record_type.strip():
            raise ExportError("invalid snapshot")
        generated = meta.get("generated")
        generated_at = generated.get("at", "") if isinstance(generated, dict) else ""
        verified = meta.get("verified")
        verification_events = verified if isinstance(verified, list) else [verified]
        trust = "human-reviewed" if any(isinstance(v, dict) and isinstance(v.get("by"), str) and v["by"].startswith("human:") for v in verification_events) else ("unverified" if verified is None else "machine-confirmed")
        sources = meta.get("sources", [])
        provenance_refs = []
        if isinstance(sources, list):
            for source in sources:
                resource = source.get("resource") if isinstance(source, dict) else None
                if isinstance(resource, str) and resource.strip() and not any(ord(c) < 32 for c in resource):
                    # Provenance is deliberately limited to visible local OKF
                    # records. Arbitrary URLs may carry credentials or leak refs.
                    try:
                        ref = _safe_rel(resource.strip())
                    except ExportError:
                        continue
                    if ref in records and ref.startswith("okf/") and ref.endswith(".md"):
                        provenance_refs.append(ref[:256])
        nodes.append({
            "id": rel,
            "title": title,
            "type": record_type,
            "status": str(meta.get("status", "stable")),
            "trust": trust,
            "generated": generated_at if isinstance(generated_at, str) else "",
            "provenance": "; ".join(provenance_refs[:3]),
            "excerpt": " ".join(body.strip().split())[:320],
        })
    return {"meta": {"project": "Filtered local export", "version": "0.7.5", "privacy": "Principal-filtered snapshot"}, "nodes": nodes, "edges": edges}


def build_export(package: Path, principal: str) -> dict[str, Any]:
    root_fd = _open_directory(package)
    try:
        return _build_export(root_fd, principal)
    finally:
        os.close(root_fd)


def build_core_snapshot_export(package: Path, principal: str, project_id: str) -> dict[str, Any]:
    """Consume one owner-only package produced by core ``export snapshot``."""
    if not isinstance(project_id, str) or not PROJECT_ID_RE.fullmatch(project_id):
        raise ExportError("invalid snapshot")
    root_fd = _open_directory(package)
    try:
        return _build_export(root_fd, principal, expected_project_id=project_id)
    finally:
        os.close(root_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--principal", required=True)
    args = parser.parse_args()
    try:
        result = build_export(args.package, args.principal)
    except ExportError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
