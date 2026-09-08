#!/usr/bin/env python3
"""Deterministic, custody-aware replication and staged OpenClaw adapter.

This module intentionally uses only the Python standard library.  The shell
CLI owns project identity and mutation policy; this file owns the bounded
archive/profile formats and their read-only validation.  Nothing in this
module writes an OKF file.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


SCHEMA_VERSION = 3
OKF_VERSION = "0.2"
REPLICATION_FORMAT = "llm-brain-replication.v1"
OPENCLAW_VERSION = "2026.9.2"
OPENCLAW_PROFILE = "openclaw-memory-core-2026.9.2"
MAX_FILE_BYTES = 10 * 1024 * 1024
READ_ONLY_POLICY = {
    "external_observation": True,
    "canonical_write": False,
    "reciprocal_write": False,
}

_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_SAFE_PART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
_SECRET = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"sk-(?:proj-)?[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|"
    r"gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"(?:api[_-]?key|secret|password|token)\s*[:=]\s*\"?[A-Za-z0-9_./+=-]{16,}",
    re.IGNORECASE,
)
_REF_PATH = re.compile(
    r"(?<![A-Za-z0-9_.-])((?:okf|episodes|review|sources)/"
    r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\.md)(?![A-Za-z0-9_.-])"
)
_REF_URI = re.compile(
    r"\b(okf|episode|episodes|review|source|sources)://([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
)


class LaneError(Exception):
    """An expected, user-correctable lane validation failure."""

    def __init__(self, message: str, code: int = 65) -> None:
        super().__init__(message)
        self.code = code


def error(message: str, code: int = 65) -> None:
    raise LaneError(message, code)


def validate_read_only_policy(value: Mapping[str, Any], context: str, require_all: bool = False) -> None:
    """Require exact read-only policy claims at a trust boundary."""
    for key, expected in READ_ONLY_POLICY.items():
        if key not in value:
            if require_all:
                error("%s missing %s policy flag" % (context, key), 65)
            continue
        actual = value[key]
        if type(actual) is not bool or actual is not expected:
            error("%s has invalid %s policy flag" % (context, key), 73)


def metadata_text(value: Any, default: str, field: str) -> str:
    """Keep exported provenance scalar; never stringify nested hidden metadata."""
    if value is None or value == "":
        return default
    if not isinstance(value, str) or "\x00" in value or any(ord(char) < 32 and char not in "\t\n\r" for char in value):
        error("OpenClaw %s metadata must be plain text" % field, 65)
    if len(value.encode("utf-8")) > MAX_FILE_BYTES:
        error("OpenClaw %s metadata exceeds 10 MiB bound" % field, 65)
    if _SECRET.search(value):
        error("OpenClaw metadata is protected", 65)
    return value


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def validate_stage_metadata(path: Path, expected: Mapping[str, Any], context: str) -> Dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        error("%s metadata is missing" % context, 73)
    data = read_bounded(path)
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        error("%s metadata is not valid JSON" % context, 73)
    if not isinstance(value, dict) or canonical_json(value) != data:
        error("%s metadata is not deterministic JSON" % context, 73)
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            error("%s metadata has invalid %s" % (context, key), 73)
    validate_read_only_policy(value, context, require_all=True)
    return value


def valid_project_id(value: str) -> bool:
    return bool(_ID.fullmatch(value)) and "/" not in value and "\\" not in value


def safe_relative(value: str) -> bool:
    if not isinstance(value, str):
        return False
    if not value or "\\" in value or "\x00" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and all(part not in ("", ".") for part in path.parts)


def safe_archive_path(value: str) -> bool:
    return safe_relative(value) and value != "manifest.json" and value.startswith(("okf/", "episodes/", "review/", "sources/"))


def read_bounded(path: Path) -> bytes:
    if path.is_symlink():
        error("symlinked file is not permitted: %s" % path, 73)
    try:
        size = path.stat().st_size
    except OSError as exc:
        error("unable to stat file: %s" % path, 66)
    if size > MAX_FILE_BYTES:
        error("file exceeds 10 MiB bound: %s" % path, 65)
    try:
        data = path.read_bytes()
    except OSError as exc:
        error("unable to read file: %s" % path, 66)
    if len(data) != size:
        error("file changed while reading: %s" % path, 73)
    return data


def text_for(data: bytes, path: str = "payload") -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        error("non-UTF-8 text is not permitted: %s" % path, 65)
    return ""


def scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        if value[0] == '"':
            try:
                decoded = json.loads(value)
                return decoded if isinstance(decoded, str) else str(decoded)
            except (TypeError, ValueError):
                pass
        return value[1:-1]
    return value


def frontmatter(data: bytes, path: str = "payload") -> Dict[str, str]:
    text = text_for(data, path)
    if not text.startswith("---\n"):
        return {}
    result: Dict[str, str] = {}
    lines = text.splitlines()[1:]
    for line in lines:
        if line.strip() == "---":
            break
        match = re.match(r"^([A-Za-z][A-Za-z0-9_.-]*):\s*(.*)$", line)
        if not match:
            continue
        key, value = match.groups()
        result[key] = scalar(value)
    return result


def sensitivity(meta: Mapping[str, str]) -> str:
    return (meta.get("brain_sensitivity") or meta.get("sensitivity") or "internal").strip().lower()


def protected(meta: Mapping[str, str], data: bytes, rel: str) -> Optional[str]:
    if "quarantine" in PurePosixPath(rel).parts:
        return "quarantine-path"
    level = sensitivity(meta)
    if level in {"restricted", "secret", "private", "quarantine"}:
        return "sensitivity-%s" % level
    state = (meta.get("brain_review_state") or meta.get("review_state") or "").lower()
    if state == "quarantine":
        return "quarantine-state"
    try:
        if _SECRET.search(text_for(data, rel)):
            return "secret-scan"
    except LaneError:
        return "non-utf8"
    return None


def relpath(path: Path, root: Path) -> str:
    try:
        value = path.relative_to(root).as_posix()
    except ValueError:
        error("path escapes project root: %s" % path, 65)
    if not safe_relative(value):
        error("unsafe relative path: %s" % value, 65)
    return value


def iter_markdown(root: Path, prefix: str) -> Iterable[Tuple[str, Path]]:
    base = root / prefix
    if not base.is_dir():
        return []
    result: List[Tuple[str, Path]] = []
    for path in sorted(base.rglob("*.md"), key=lambda item: item.relative_to(root).as_posix()):
        if path.is_symlink() or not path.is_file():
            continue
        result.append((relpath(path, root), path))
    return result


def index_records(root: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for prefix in ("okf", "episodes", "review"):
        for rel, path in iter_markdown(root, prefix):
            meta = frontmatter(read_bounded(path), rel)
            for key in ("brain_claim_id", "brain_procedure_id", "brain_reference_id", "brain_topic_id", "brain_episode_id", "brain_candidate_id", "brain_review_id"):
                value = meta.get(key, "").strip()
                if value and value not in result:
                    result[value] = rel
            stem = Path(rel).stem
            if stem and stem not in result:
                result[stem] = rel
    return result


def path_from_reference(reference: str, indexes: Mapping[str, str], root: Path) -> Optional[str]:
    if not isinstance(reference, str):
        return None
    reference = scalar(reference.strip().strip("`"))
    if not reference:
        return None
    if reference.startswith("file://"):
        return None
    if "://" in reference:
        scheme, value = reference.split("://", 1)
        if scheme in {"okf", "episode", "episodes", "review", "source", "sources"}:
            if scheme == "okf":
                reference = value if value.startswith("okf/") else "okf/" + value
            elif scheme in {"source", "sources"}:
                reference = value if value.startswith("sources/") else "sources/" + value
            elif scheme == "review":
                reference = value if value.startswith("review/") else "review/" + value
            else:
                exact = indexes.get(value) or indexes.get(Path(value).stem)
                if exact and exact.startswith("episodes/"):
                    return exact
                reference = value if value.startswith("episodes/") else "episodes/" + value
    if reference.startswith(("okf/", "episodes/", "review/", "sources/")):
        if not reference.endswith(".md") and reference.startswith(("episodes/", "review/")):
            reference += ".md"
        if safe_relative(reference) and (root / reference).is_file():
            return reference
    exact = indexes.get(reference) or indexes.get(Path(reference).stem)
    if exact and (root / exact).is_file():
        return exact
    return None


def references_from(rel: str, data: bytes) -> List[str]:
    text = text_for(data, rel)
    found: Set[str] = set()
    for match in _REF_PATH.finditer(text):
        found.add(match.group(1))
    for match in _REF_URI.finditer(text):
        scheme, value = match.groups()
        if scheme == "okf":
            found.add(value if value.startswith("okf/") else "okf/" + value)
        elif scheme in {"source", "sources"}:
            found.add(value if value.startswith("sources/") else "sources/" + value)
        elif scheme == "review":
            found.add(value if value.startswith("review/") else "review/" + value)
        else:
            found.add(value if value.startswith("episodes/") else "episodes/" + value)
    return sorted(found)


def list_values(value: Any, field: str = "visibility") -> List[str]:
    """Parse a visibility field without accepting malformed structured data."""
    if value is None or value == "":
        return []
    if isinstance(value, list):
        result: List[str] = []
        for item in value:
            if not isinstance(item, str) or not item.strip():
                error("OpenClaw %s must contain plain-text principals" % field, 65)
            result.append(item.strip())
        return result
    if not isinstance(value, str):
        error("OpenClaw %s must be plain-text principals" % field, 65)
    raw = value.strip()
    if not raw:
        return []
    if raw.startswith("[") and raw.endswith("]"):
        try:
            loaded = json.loads(raw.replace("'", '"'))
        except (TypeError, ValueError):
            loaded = None
        if isinstance(loaded, list):
            return list_values(loaded, field)
    return [scalar(item.strip()) for item in raw.strip("[]").split(",") if scalar(item.strip())]


def visibility_identities(meta: Mapping[str, Any], context: str) -> Tuple[str, List[str]]:
    """Return one consistent identity and its audience, failing closed on types."""
    identities: List[Tuple[str, str]] = []
    for key in ("brain_principal", "principal", "agent_id", "owner"):
        if key not in meta or meta[key] is None or meta[key] == "":
            continue
        value = meta[key]
        if not isinstance(value, str) or not value.strip():
            error("OpenClaw %s %s must be a plain-text principal" % (context, key), 65)
        identities.append((key, value.strip()))
    unique = {value for _, value in identities}
    if len(unique) > 1:
        error("OpenClaw %s principal metadata is inconsistent" % context, 65)
    audience: List[str] = []
    for key in ("brain_audience", "brain_principals", "audience", "principals"):
        if key in meta:
            audience.extend(list_values(meta[key], "%s %s" % (context, key)))
    return (next(iter(unique)) if unique else ""), audience


def principal_matches(meta: Mapping[str, Any], principal: str) -> bool:
    identity, audience = visibility_identities(meta, "record")
    if identity:
        return identity == principal
    return principal in audience


def has_visibility_metadata(meta: Mapping[str, Any]) -> bool:
    identity, audience = visibility_identities(meta, "record")
    return bool(identity or audience)


def visible_for_scope(meta: Mapping[str, str], scope: str, principal: str) -> bool:
    if not has_visibility_metadata(meta):
        return True
    return scope == "principal" and principal_matches(meta, principal)


def resolve_review(root: Path, ref: str, indexes: Mapping[str, str]) -> Optional[str]:
    if not ref:
        return None
    candidate = ref
    if not candidate.startswith("review/"):
        candidate = "review/" + candidate
    if not candidate.endswith(".md"):
        candidate += ".md"
    if safe_relative(candidate) and (root / candidate).is_file() and not (root / candidate).is_symlink():
        return candidate
    return indexes.get(ref)


def project_matches(meta: Mapping[str, Any], project_id: str) -> bool:
    """Reject an explicitly foreign record while allowing raw custody files."""
    record_project = meta.get("brain_project_id")
    return not record_project or record_project == project_id


def source_sidecar(rel: str) -> str:
    return rel + ".sha256"


def validate_sidecar(content: bytes, expected_hash: str, source_rel: str) -> None:
    text = text_for(content, source_rel + ".sha256")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        error("invalid custody sidecar: %s" % (source_rel + ".sha256"), 65)
    fields = lines[0].split()
    if len(fields) < 2 or fields[0].lower() != expected_hash or fields[-1] != Path(source_rel).name:
        error("custody sidecar hash/name mismatch: %s" % (source_rel + ".sha256"), 65)


def collect_replication(project_dir: Path, project_id: str, scope: str, principal: str, review_ref: str) -> Tuple[Dict[str, Any], Dict[str, bytes]]:
    if not valid_project_id(project_id):
        error("invalid project id: %s" % project_id, 64)
    if not isinstance(scope, str) or scope not in {"project", "principal"}:
        error("invalid replication scope: %s" % scope, 64)
    if scope == "principal" and (not principal or not review_ref):
        error("principal replication requires --principal ID and --review REF", 64)
    project_dir = project_dir.resolve()
    if not project_dir.is_dir():
        error("project directory is missing: %s" % project_dir, 66)
    indexes = index_records(project_dir)
    selected: Set[str] = set()
    excluded: List[Dict[str, str]] = []
    warnings: Set[str] = set()
    candidate_paths = [
        rel for rel, _ in iter_markdown(project_dir, "okf")
        if rel not in {"okf/index.md", "okf/log.md"} and not rel.startswith("okf/retractions/")
    ]

    resolved_review = resolve_review(project_dir, review_ref, indexes) if review_ref else None
    if review_ref and not resolved_review:
        error("replication review reference is missing: %s" % review_ref, 66)
    if scope == "principal":
        review_data = read_bounded(project_dir / resolved_review)  # type: ignore[arg-type]
        review_meta = frontmatter(review_data, resolved_review or "review")
        if not project_matches(review_meta, project_id):
            error("replication review belongs to another project", 73)
        if review_meta.get("brain_principal", "") != principal:
            error("replication review is not bound to principal: %s" % principal, 73)
        if protected(review_meta, review_data, resolved_review or "review"):
            error("replication review is protected or secret", 65)
    elif resolved_review:
        review_data = read_bounded(project_dir / resolved_review)
        review_meta = frontmatter(review_data, resolved_review)
        if not project_matches(review_meta, project_id):
            error("replication review belongs to another project", 73)
        if not visible_for_scope(review_meta, scope, principal):
            error("replication review is outside the requested scope", 73)

    for rel in candidate_paths:
        path = project_dir / rel
        data = read_bounded(path)
        meta = frontmatter(data, rel)
        if not project_matches(meta, project_id):
            excluded.append({"path": rel, "reason": "project-mismatch"})
            continue
        reason = protected(meta, data, rel)
        if reason:
            excluded.append({"path": rel, "reason": reason})
            continue
        if not visible_for_scope(meta, scope, principal):
            excluded.append({"path": rel, "reason": "visibility-scope"})
            continue
        selected.add(rel)

    if resolved_review:
        selected.add(resolved_review)

    queue = sorted(selected)
    visited: Set[str] = set()
    while queue:
        current = queue.pop(0)
        if current in visited:
            continue
        visited.add(current)
        path = project_dir / current
        if not path.is_file():
            warnings.add("missing-reference:%s" % current)
            continue
        data = read_bounded(path)
        meta = frontmatter(data, current)
        if not project_matches(meta, project_id):
            selected.discard(current)
            excluded.append({"path": current, "reason": "project-mismatch"})
            warnings.add("project-reference-excluded")
            continue
        reason = protected(meta, data, current)
        if reason:
            if current in selected:
                selected.remove(current)
                excluded.append({"path": current, "reason": reason})
            warnings.add("protected-reference:%s" % current)
            continue
        if not visible_for_scope(meta, scope, principal) and current != resolved_review:
            warnings.add("principal-reference-excluded:%s" % current)
            selected.discard(current)
            continue
        for ref in references_from(current, data):
            resolved = path_from_reference(ref, indexes, project_dir)
            if resolved is None:
                warnings.add("missing-reference:%s" % ref)
                continue
            if resolved not in visited and resolved not in selected:
                if resolved.startswith(("okf/", "episodes/", "review/", "sources/")):
                    target_data = read_bounded(project_dir / resolved)
                    target_meta = frontmatter(target_data, resolved)
                    if not project_matches(target_meta, project_id):
                        excluded.append({"path": resolved, "reason": "project-mismatch"})
                        warnings.add("project-reference-excluded")
                        continue
                    if resolved.startswith("okf/retractions/"):
                        target_ref = target_meta.get("brain_retracts", "")
                        target_path = path_from_reference(target_ref, indexes, project_dir)
                        if not target_ref or (target_path not in selected and target_ref not in selected):
                            excluded.append({"path": resolved, "reason": "unrelated-retraction"})
                            warnings.add("unrelated-retraction")
                            continue
                    if not visible_for_scope(target_meta, scope, principal):
                        warnings.add("principal-reference-excluded:%s" % resolved)
                        continue
                selected.add(resolved)
                queue.append(resolved)

    # Retraction/tombstone state is included only when it applies to a selected
    # canonical path or record.  Unrelated retractions would be hidden data.
    for rel, path in iter_markdown(project_dir, "okf/retractions"):
        data = read_bounded(path)
        meta = frontmatter(data, rel)
        if not project_matches(meta, project_id):
            excluded.append({"path": rel, "reason": "project-mismatch"})
            continue
        reason = protected(meta, data, rel)
        target = meta.get("brain_retracts", "")
        if reason:
            excluded.append({"path": rel, "reason": reason})
        elif not visible_for_scope(meta, scope, principal):
            excluded.append({"path": rel, "reason": "visibility-scope"})
        else:
            target_path = path_from_reference(target, indexes, project_dir) if target else None
            if target and (target in selected or target_path in selected):
                selected.add(rel)
            else:
                excluded.append({"path": rel, "reason": "unrelated-retraction"})

    payload: Dict[str, bytes] = {}
    entry_meta: Dict[str, Dict[str, Any]] = {}
    for rel in sorted(selected):
        path = project_dir / rel
        if not path.is_file() or path.is_symlink():
            warnings.add("missing-reference:%s" % rel)
            continue
        data = read_bounded(path)
        meta = frontmatter(data, rel)
        reason = protected(meta, data, rel)
        if reason:
            excluded.append({"path": rel, "reason": reason})
            continue
        if not visible_for_scope(meta, scope, principal):
            excluded.append({"path": rel, "reason": "visibility-scope"})
            continue
        payload[rel] = data
        if rel.startswith("okf/"):
            kind = "tombstone" if "/retractions/" in rel else "canonical"
        elif rel.startswith("episodes/"):
            kind = "episode"
        elif rel.startswith("review/"):
            kind = "review"
        else:
            kind = "custody"
        entry_meta[rel] = {"kind": kind, "sensitivity": sensitivity(meta)}

    # Source custody is the only binary-ish payload and must be explicitly
    # referenced.  Include its sidecar as a separately hashed payload member.
    source_refs = sorted(rel for rel in payload if rel.startswith("sources/") and rel.endswith(".md"))
    for source_rel in source_refs:
        source_hash = sha256_bytes(payload[source_rel])
        side_rel = source_sidecar(source_rel)
        side_path = project_dir / side_rel
        if not side_path.is_file() or side_path.is_symlink():
            warnings.add("missing-sidecar:%s" % source_rel)
            del payload[source_rel]
            entry_meta.pop(source_rel, None)
            continue
        side_data = read_bounded(side_path)
        validate_sidecar(side_data, source_hash, source_rel)
        payload[side_rel] = side_data
        entry_meta[side_rel] = {"kind": "custody-sidecar", "sensitivity": "internal", "parent": source_rel}
        entry_meta[source_rel]["sidecar"] = side_rel

    entries: List[Dict[str, Any]] = []
    for rel in sorted(payload):
        data = payload[rel]
        item: Dict[str, Any] = {
            "path": rel,
            "sha256": sha256_bytes(data),
            "bytes": len(data),
            "kind": entry_meta[rel]["kind"],
            "sensitivity": entry_meta[rel].get("sensitivity", "internal"),
        }
        for key in ("sidecar", "parent"):
            if key in entry_meta[rel]:
                item[key] = entry_meta[rel][key]
        entries.append(item)

    # Deduplicate warnings/exclusions to keep the manifest byte-stable.  A
    # filtered record's path is itself hidden metadata; preserve only the
    # reason class and never disclose the excluded path or count of instances.
    unique_excluded = sorted(
        ({"path": "<redacted>", "reason": item["reason"]} for item in excluded),
        key=lambda item: item["reason"],
    )
    unique_excluded = [
        item for index, item in enumerate(unique_excluded)
        if index == 0 or item != unique_excluded[index - 1]
    ]
    warning_prefixes = ("missing-reference", "missing-sidecar", "protected-reference", "principal-reference-excluded")
    safe_warnings = sorted(
        {warning.split(":", 1)[0] if warning.startswith(warning_prefixes) else warning for warning in warnings}
    )
    manifest: Dict[str, Any] = {
        "format": REPLICATION_FORMAT,
        "manifest_version": 1,
        "schema_version": SCHEMA_VERSION,
        "okf_version": OKF_VERSION,
        "project_id": project_id,
        "scope": scope,
        "principal": principal if scope == "principal" else None,
        "review_ref": resolved_review if resolved_review else None,
        "review_hash_sha256": sha256_bytes(payload[resolved_review]) if resolved_review and resolved_review in payload else None,
        "referenced_custody_only": True,
        "external_observation": True,
        "canonical_write": False,
        "reciprocal_write": False,
        "entries": entries,
        "excluded": unique_excluded,
        "warnings": safe_warnings,
    }
    return manifest, payload


def tar_info(name: str, data: bytes) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    return info


def write_archive(output: Path, manifest: Dict[str, Any], payload: Mapping[str, bytes]) -> Tuple[Path, bytes]:
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest_bytes = canonical_json(manifest)
    temporary = output.with_name(".%s.tmp.%s" % (output.name, os.getpid()))
    try:
        with temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
                with tarfile.open(mode="w", fileobj=zipped, format=tarfile.PAX_FORMAT) as archive:
                    archive.addfile(tar_info("manifest.json", manifest_bytes), io.BytesIO(manifest_bytes))
                    for name in sorted(payload):
                        archive.addfile(tar_info(name, payload[name]), io.BytesIO(payload[name]))
        os.replace(str(temporary), str(output))
    finally:
        if temporary.exists():
            temporary.unlink()
    output.with_name(output.name + ".manifest.json").write_bytes(manifest_bytes)
    output.with_name(output.name + ".sha256").write_text("%s  %s\n" % (sha256_file(output), output.name), encoding="utf-8")
    return output, manifest_bytes


def validate_manifest(manifest: Any) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    if not isinstance(manifest, dict):
        error("replication manifest is not an object", 65)
    required = (
        "format",
        "manifest_version",
        "schema_version",
        "okf_version",
        "project_id",
        "scope",
        "referenced_custody_only",
        "external_observation",
        "canonical_write",
        "reciprocal_write",
        "entries",
    )
    for key in required:
        if key not in manifest:
            error("replication manifest missing %s" % key, 65)
    if manifest.get("format") != REPLICATION_FORMAT or manifest.get("manifest_version") != 1:
        error("unsupported replication manifest format", 65)
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("okf_version") != OKF_VERSION:
        error("replication schema/OKF version mismatch", 65)
    validate_read_only_policy(manifest, "replication manifest", require_all=True)
    if type(manifest.get("referenced_custody_only")) is not bool or manifest.get("referenced_custody_only") is not True:
        error("replication manifest has invalid referenced_custody_only policy flag", 73)
    project_id = manifest.get("project_id")
    if not isinstance(project_id, str) or not valid_project_id(project_id):
        error("invalid replication project id", 65)
    scope = manifest.get("scope")
    if not isinstance(scope, str) or scope not in {"project", "principal"}:
        error("invalid replication scope", 65)
    principal = manifest.get("principal")
    if scope == "principal" and (not isinstance(principal, str) or not principal):
        error("principal replication manifest lacks exact principal", 73)
    if scope == "project" and principal not in (None, ""):
        error("project replication manifest has an unexpected principal", 73)
    review_ref = manifest.get("review_ref")
    review_hash = manifest.get("review_hash_sha256")
    if review_ref is not None:
        if (
            not isinstance(review_ref, str)
            or not safe_relative(review_ref)
            or not review_ref.startswith("review/")
            or not review_ref.endswith(".md")
        ):
            error("replication manifest has invalid review binding", 73)
        if not isinstance(review_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", review_hash):
            error("replication manifest lacks exact review hash", 73)
    elif review_hash is not None:
        error("replication manifest has an orphan review hash", 73)
    if scope == "principal" and review_ref is None:
        error("principal replication manifest lacks exact review binding", 73)
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        error("replication entries are not a list", 65)
    seen: Set[str] = set()
    normal: List[Dict[str, Any]] = []
    for item in entries:
        if not isinstance(item, dict):
            error("replication entry is not an object", 65)
        path = item.get("path")
        digest = item.get("sha256")
        size = item.get("bytes")
        if not isinstance(path, str) or not safe_archive_path(path) or path in seen:
            error("invalid or duplicate replication path: %s" % path, 65)
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            error("invalid replication hash: %s" % path, 65)
        if not isinstance(size, int) or size < 0 or size > MAX_FILE_BYTES:
            error("invalid replication byte count: %s" % path, 65)
        kind = item.get("kind")
        if not isinstance(kind, str) or kind not in {"canonical", "episode", "review", "tombstone", "custody", "custody-sidecar"}:
            error("invalid replication entry kind: %s" % path, 65)
        seen.add(path)
        normal.append(item)
    if [item["path"] for item in normal] != sorted(item["path"] for item in normal):
        error("replication entries are not deterministically ordered", 65)
    return manifest, normal


def archive_kind_for_path(path: str) -> Optional[str]:
    if path.startswith("okf/retractions/"):
        return "tombstone"
    if path.startswith("okf/"):
        return "canonical"
    if path.startswith("episodes/"):
        return "episode"
    if path.startswith("review/"):
        return "review"
    if path.startswith("sources/") and path.endswith(".md.sha256"):
        return "custody-sidecar"
    if path.startswith("sources/") and path.endswith(".md"):
        return "custody"
    return None


def validate_archive_scope(manifest: Mapping[str, Any], entries: Sequence[Mapping[str, Any]], raw: Mapping[str, bytes]) -> None:
    """Revalidate imported payloads instead of trusting an untrusted manifest."""
    project_id = manifest["project_id"]
    scope = manifest["scope"]
    principal = manifest.get("principal") or ""
    by_path = {item["path"]: item for item in entries}

    for item in entries:
        path = item["path"]
        expected_kind = archive_kind_for_path(path)
        if expected_kind != item["kind"]:
            error("replication entry kind does not match path: %s" % path, 65)
        if item.get("sensitivity") is not None and not isinstance(item.get("sensitivity"), str):
            error("replication entry sensitivity is not text: %s" % path, 65)
        if item["kind"] == "custody-sidecar":
            parent = item.get("parent")
            if not isinstance(parent, str) or parent not in by_path or by_path[parent]["kind"] != "custody":
                error("custody sidecar parent is invalid: %s" % path, 65)
            if not parent.startswith("sources/") or not parent.endswith(".md"):
                error("custody sidecar parent is not source custody: %s" % path, 65)
            if item.get("sensitivity") != "internal":
                error("custody sidecar sensitivity is invalid: %s" % path, 65)
            continue

        data = raw[path]
        meta = frontmatter(data, path) if path.endswith(".md") else {}
        if not project_matches(meta, project_id):
            error("replication payload belongs to another project: %s" % path, 73)
        if not visible_for_scope(meta, scope, principal):
            error("replication payload is outside manifest scope: %s" % path, 73)
        if item.get("sensitivity") != sensitivity(meta):
            error("replication entry sensitivity mismatch: %s" % path, 73)

    for item in entries:
        if item["kind"] == "custody":
            sidecar = item.get("sidecar")
            if not isinstance(sidecar, str) or sidecar not in by_path or by_path[sidecar]["kind"] != "custody-sidecar":
                error("custody sidecar is missing: %s" % item["path"], 65)
            if by_path[sidecar].get("parent") != item["path"]:
                error("custody sidecar parent mismatch: %s" % item["path"], 73)

    review_ref = manifest.get("review_ref")
    if review_ref is not None:
        review_item = by_path.get(review_ref)
        if review_item is None or review_item["kind"] != "review":
            error("replication review entry is missing: %s" % review_ref, 73)
        if sha256_bytes(raw[review_ref]) != manifest["review_hash_sha256"]:
            error("replication review hash mismatch: %s" % review_ref, 73)


def validate_archive_sidecar(archive_path: Path) -> None:
    sidecar = archive_path.with_name(archive_path.name + ".sha256")
    if not sidecar.is_file() or sidecar.is_symlink():
        error("replication archive custody sidecar is missing: %s" % sidecar, 65)
    validate_sidecar(read_bounded(sidecar), sha256_file(archive_path), archive_path.name)


def validate_stage_tree(output: Path, expected_paths: Set[str], context: str) -> None:
    """Require an idempotent stage to be a closed, regular-file tree."""
    allowed = {"manifest.json", "stage.json", "observations"}
    try:
        children = list(output.iterdir())
    except OSError:
        error("%s output cannot be listed: %s" % (context, output), 73)
    if {child.name for child in children} != allowed:
        error("%s output contains unmanifested artefacts: %s" % (context, output), 73)
    for name in ("manifest.json", "stage.json"):
        path = output / name
        if path.is_symlink() or not path.is_file():
            error("%s metadata is not a regular file: %s" % (context, name), 73)
    observations = output / "observations"
    if observations.is_symlink() or not observations.is_dir():
        error("%s observations directory is invalid" % context, 73)
    actual: Set[str] = set()
    for path in observations.rglob("*"):
        if path.is_symlink():
            error("%s contains a symlink: %s" % (context, path), 73)
        if path.is_file():
            rel = path.relative_to(observations).as_posix()
            if not safe_relative(rel):
                error("%s contains an unsafe path: %s" % (context, rel), 73)
            actual.add(rel)
        elif not path.is_dir():
            error("%s contains a non-regular observation: %s" % (context, path), 73)
    if actual != expected_paths:
        extra = sorted(actual - expected_paths)
        missing = sorted(expected_paths - actual)
        error("%s observation tree conflict extra=%s missing=%s" % (context, extra, missing), 73)


def read_archive(archive_path: Path) -> Tuple[Dict[str, Any], Dict[str, bytes], bytes]:
    if not archive_path.is_file() or archive_path.is_symlink():
        error("replication archive is missing: %s" % archive_path, 66)
    try:
        archive = tarfile.open(archive_path, mode="r:gz")
    except (OSError, tarfile.TarError) as exc:
        error("invalid replication tar archive", 65)
    members = archive.getmembers()
    names: Set[str] = set()
    raw: Dict[str, bytes] = {}
    try:
        for member in members:
            name = member.name
            if not safe_relative(name) or name in names:
                error("unsafe or duplicate replication archive path: %s" % name, 65)
            names.add(name)
            if not member.isfile() or member.issym() or member.islnk():
                error("replication archive contains non-regular member: %s" % name, 65)
            extracted = archive.extractfile(member)
            if extracted is None:
                error("unable to read archive member: %s" % name, 65)
            data = extracted.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                error("archive member exceeds 10 MiB bound: %s" % name, 65)
            raw[name] = data
    finally:
        archive.close()
    if "manifest.json" not in raw:
        error("replication archive lacks manifest.json", 65)
    manifest_bytes = raw.pop("manifest.json")
    try:
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        error("replication manifest is not valid UTF-8 JSON", 65)
    canonical_manifest = canonical_json(manifest)
    if canonical_manifest != manifest_bytes:
        error("replication manifest is not deterministic JSON", 65)
    manifest, entries = validate_manifest(manifest)
    expected = {item["path"] for item in entries}
    if set(raw) != expected:
        extra = sorted(set(raw) - expected)
        missing = sorted(expected - set(raw))
        error("replication payload mismatch extra=%s missing=%s" % (extra, missing), 65)
    for item in entries:
        data = raw[item["path"]]
        if len(data) != item["bytes"] or sha256_bytes(data) != item["sha256"]:
            error("replication path/hash mismatch: %s" % item["path"], 65)
        meta = frontmatter(data, item["path"]) if item["path"].endswith(".md") else {}
        reason = protected(meta, data, item["path"])
        if reason:
            error("replication payload is protected: %s (%s)" % (item["path"], reason), 65)
        if item["kind"] == "custody-sidecar":
            parent = item.get("parent")
            if not isinstance(parent, str) or parent not in raw:
                error("custody sidecar parent is missing: %s" % item["path"], 65)
    validate_archive_scope(manifest, entries, raw)
    for item in entries:
        if item["kind"] == "custody":
            sidecar = item["sidecar"]
            validate_sidecar(raw[sidecar], item["sha256"], item["path"])
    validate_archive_sidecar(archive_path)
    return manifest, raw, manifest_bytes


def output_is_canonical(output: Path, project_dir: Optional[Path]) -> None:
    if project_dir is None:
        return
    try:
        output.resolve().relative_to((project_dir / "okf").resolve())
    except ValueError:
        return
    error("staging output may not be inside canonical okf/", 73)


def stage_replication(archive_path: Path, project_id: Optional[str], output: Path, dry_run: bool, project_dir: Optional[Path] = None) -> Dict[str, Any]:
    manifest, raw, manifest_bytes = read_archive(archive_path)
    archive_project = manifest["project_id"]
    if project_id and project_id != archive_project:
        error("replication project identity mismatch", 73)
    actual_project = project_id or archive_project
    output = output.expanduser()
    if output.is_symlink():
        error("replication stage output is symlinked: %s" % output, 73)
    output = output.resolve()
    if not dry_run and project_dir is None:
        error("replication stage requires project context for canonical protection", 64)
    if not dry_run:
        output_is_canonical(output, project_dir)
    if dry_run:
        return {"status": "dry-run", "project_id": actual_project, "scope": manifest["scope"], "entries": len(manifest["entries"]), "canonical_write": False, "external_observation": True}
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            error("replication stage output is not a directory: %s" % output, 73)
        existing_manifest = output / "manifest.json"
        if existing_manifest.is_symlink() or not existing_manifest.is_file() or read_bounded(existing_manifest) != manifest_bytes:
            error("replication stage conflict: %s" % output, 73)
        validate_stage_metadata(
            output / "stage.json",
            {
                "format": "llm-brain-external-observation-stage.v1",
                "schema_version": SCHEMA_VERSION,
                "okf_version": OKF_VERSION,
                "project_id": actual_project,
                "manifest_sha256": sha256_bytes(manifest_bytes),
            },
            "replication stage",
        )
        expected_paths = {item["path"] for item in manifest["entries"]}
        validate_stage_tree(output, expected_paths, "replication stage")
        for item in manifest["entries"]:
            staged = output / "observations" / item["path"]
            if staged.is_symlink() or not staged.is_file() or sha256_file(staged) != item["sha256"]:
                error("replication stage file conflict: %s" % item["path"], 73)
        return {"status": "idempotent", "project_id": actual_project, "scope": manifest["scope"], "entries": len(manifest["entries"]), "output": str(output), "canonical_write": False, "external_observation": True}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".replication-stage.", dir=str(output.parent)))
    try:
        (temporary / "observations").mkdir()
        (temporary / "manifest.json").write_bytes(manifest_bytes)
        stage_meta = {
            "format": "llm-brain-external-observation-stage.v1",
            "schema_version": SCHEMA_VERSION,
            "okf_version": OKF_VERSION,
            "project_id": actual_project,
            "manifest_sha256": sha256_bytes(manifest_bytes),
            "canonical_write": False,
            "reciprocal_write": False,
            "external_observation": True,
        }
        (temporary / "stage.json").write_bytes(canonical_json(stage_meta))
        for item in manifest["entries"]:
            target = temporary / "observations" / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw[item["path"]])
        os.replace(str(temporary), str(output))
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))
    return {"status": "staged", "project_id": actual_project, "scope": manifest["scope"], "entries": len(manifest["entries"]), "output": str(output), "canonical_write": False, "external_observation": True}


def do_replication_export(args: argparse.Namespace) -> Dict[str, Any]:
    manifest, payload = collect_replication(Path(args.project_dir), args.project_id, args.scope, args.principal or "", args.review or "")
    output = Path(args.output) if args.output else Path(args.project_dir) / "exports" / (args.project_id + "-replication.tar.gz")
    output_is_canonical(output.expanduser().resolve(), Path(args.project_dir))
    archive, manifest_bytes = write_archive(output, manifest, payload)
    return {"status": "ok", "operation": "export", "project_id": args.project_id, "scope": args.scope, "entries": len(manifest["entries"]), "excluded": len(manifest["excluded"]), "warnings": manifest["warnings"], "archive": str(archive), "manifest_sha256": sha256_bytes(manifest_bytes), "canonical_write": False}


def do_replication_import(args: argparse.Namespace) -> Dict[str, Any]:
    if bool(args.dry_run) == bool(args.stage) :
        error("replication import requires exactly one of --dry-run or --stage", 64)
    archive = Path(args.archive)
    output = Path(args.output) if args.output else Path(str(archive) + ".stage")
    project_dir = Path(args.project_dir) if args.project_dir else None
    return stage_replication(archive, args.project_id, output, bool(args.dry_run), project_dir)


def valid_openclaw_path(value: str) -> bool:
    if not safe_relative(value):
        return False
    if value in {"MEMORY.md", "USER.md"}:
        return True
    return value.startswith("memory/") and value.endswith((".md", ".json"))


def openclaw_profile_source(input_path: Path) -> Tuple[Dict[str, Any], Path]:
    input_path = input_path.expanduser()
    if input_path.is_symlink():
        error("OpenClaw profile is missing or symlinked: %s" % input_path, 66)
    input_path = input_path.resolve()
    if not input_path.exists():
        error("OpenClaw profile is missing or symlinked: %s" % input_path, 66)
    if input_path.is_file():
        if input_path.suffix.lower() != ".json":
            error("OpenClaw profile must be JSON or a profile directory", 65)
        try:
            obj = json.loads(read_bounded(input_path).decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            error("OpenClaw profile is not valid JSON", 65)
        if not isinstance(obj, dict):
            error("OpenClaw profile is not an object", 65)
        return obj, input_path.parent
    candidates = [input_path / "profile.json", input_path / "openclaw-profile.json", input_path / ".openclaw" / "profile.json", input_path / "manifest.json"]
    for candidate in candidates:
        if candidate.is_file() and not candidate.is_symlink():
            try:
                obj = json.loads(read_bounded(candidate).decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                error("OpenClaw profile is not valid JSON: %s" % candidate, 65)
            if not isinstance(obj, dict):
                error("OpenClaw profile is not an object", 65)
            return obj, candidate.parent
    error("OpenClaw profile manifest is missing", 66)
    return {}, input_path


def profile_alias(profile: Mapping[str, Any], keys: Sequence[str], label: str) -> Any:
    values = [profile[key] for key in keys if key in profile and profile[key] not in (None, "")]
    if values and any(value != values[0] for value in values[1:]):
        error("OpenClaw profile %s aliases are inconsistent" % label, 65)
    return values[0] if values else None


def normalise_openclaw(profile: Mapping[str, Any], base: Path, requested_scope: Optional[str] = None, requested_principal: Optional[str] = None) -> Dict[str, Any]:
    version = profile_alias(profile, ("version", "openclaw_version", "profile_version"), "version")
    if version != OPENCLAW_VERSION:
        error("unsupported OpenClaw version; expected %s" % OPENCLAW_VERSION, 65)
    profile_id = profile.get("profile_id")
    if profile_id != OPENCLAW_PROFILE:
        error("unsupported OpenClaw profile; expected %s" % OPENCLAW_PROFILE, 65)
    validate_read_only_policy(profile, "OpenClaw profile", require_all=True)
    scope = profile_alias(profile, ("scope", "visibility"), "scope") or "project"
    if not isinstance(scope, str) or scope not in {"project", "principal"}:
        error("OpenClaw profile scope must be project or principal", 65)
    if requested_scope and requested_scope != scope:
        error("OpenClaw scope does not match requested scope", 73)
    principal = profile_alias(profile, ("principal", "agent_id", "owner"), "principal") or ""
    if scope == "principal" and (not isinstance(principal, str) or not principal):
        error("OpenClaw principal scope is not exact", 65)
    if requested_principal and requested_principal != principal:
        error("OpenClaw principal does not match requested principal", 73)
    raw_entries = profile.get("entries") or profile.get("memories") or profile.get("records") or []
    if not isinstance(raw_entries, list):
        error("OpenClaw profile entries are not a list", 65)
    entries: List[Dict[str, Any]] = []
    seen: Set[str] = set()
    protected_scopes = {"private", "restricted", "secret", "quarantine"}
    for raw in raw_entries:
        if isinstance(raw, str):
            raw = {"path": raw}
        if not isinstance(raw, dict):
            error("OpenClaw entry is not an object", 65)
        entry_scope = raw.get("scope") or scope
        if not isinstance(entry_scope, str) or entry_scope not in ({"project", "principal"} | protected_scopes):
            error("OpenClaw entry has invalid scope", 65)
        # Private records are filtered before path validation and counting so
        # their names and malformed metadata cannot escape in diagnostics.
        if entry_scope in protected_scopes or entry_scope != scope:
            continue
        entry_identity, entry_audience = visibility_identities(raw, "entry")
        if scope == "project" and (entry_identity or entry_audience):
            continue
        if scope == "principal" and (entry_identity or entry_audience) and not principal_matches(raw, principal):
            continue
        entry_principal = raw.get("principal") or raw.get("agent_id") or principal
        if scope == "principal" and (not isinstance(entry_principal, str) or entry_principal != principal):
            continue
        if scope == "project" and any(raw.get(key) for key in ("principal", "agent_id", "owner")):
            continue
        sensitivity_value = metadata_text(raw.get("sensitivity") or raw.get("brain_sensitivity"), "internal", "sensitivity").lower()
        if sensitivity_value in protected_scopes:
            continue
        path = raw.get("path") or raw.get("source_path")
        if not isinstance(path, str) or not valid_openclaw_path(path) or path in seen:
            error("invalid or duplicate OpenClaw path", 65)
        content_value = raw.get("content")
        if content_value is None:
            source = (base / path).resolve()
            try:
                source.relative_to(base.resolve())
            except ValueError:
                error("OpenClaw entry escapes profile root: %s" % path, 65)
            if source.is_symlink() or not source.is_file():
                error("OpenClaw entry is missing: %s" % path, 66)
            data = read_bounded(source)
        elif isinstance(content_value, str):
            data = content_value.encode("utf-8")
            if len(data) > MAX_FILE_BYTES:
                error("OpenClaw entry content exceeds 10 MiB bound", 65)
        else:
            error("OpenClaw entry content must be text", 65)
        content_meta = frontmatter(data, path) if path.endswith(".md") else {}
        content_scope = content_meta.get("scope") or content_meta.get("visibility") or content_meta.get("brain_scope") or content_meta.get("brain_visibility") or scope
        if not isinstance(content_scope, str) or content_scope in protected_scopes or content_scope != scope:
            continue
        content_principal = content_meta.get("brain_principal") or content_meta.get("principal") or ""
        if scope == "principal" and content_principal and content_principal != principal:
            continue
        if scope == "project" and (content_principal or has_visibility_metadata(content_meta)):
            continue
        if scope == "principal" and has_visibility_metadata(content_meta) and not principal_matches(content_meta, principal):
            continue
        reason = protected(content_meta, data, path)
        if reason:
            if reason.startswith("sensitivity-") or reason in {"quarantine-path", "quarantine-state"}:
                continue
            error("OpenClaw entry is protected or secret", 65)
        source_type = metadata_text(raw.get("source_type") or raw.get("type"), "markdown", "source_type")
        observed_at = metadata_text(raw.get("observed_at") or raw.get("timestamp") or raw.get("created_at"), "unknown", "observed_at")
        resource = metadata_text(raw.get("resource") or raw.get("origin"), "openclaw", "resource")
        seen.add(path)
        entries.append({
            "path": path,
            "sha256": sha256_bytes(data),
            "bytes": len(data),
            "source_type": source_type,
            "observed_at": observed_at,
            "resource": resource,
            "scope": scope,
            "principal": principal if scope == "principal" else None,
            "content": data,
        })
    entries.sort(key=lambda item: item["path"])
    return {"profile_id": OPENCLAW_PROFILE, "version": OPENCLAW_VERSION, "scope": scope, "principal": principal if scope == "principal" else None, "entries": entries}


def openclaw_manifest(normal: Mapping[str, Any], project_id: Optional[str] = None) -> Tuple[Dict[str, Any], Dict[str, bytes]]:
    if normal.get("profile_id") != OPENCLAW_PROFILE or normal.get("version") != OPENCLAW_VERSION:
        error("OpenClaw normalisation is not pinned to the supported profile", 73)
    payload: Dict[str, bytes] = {}
    entries: List[Dict[str, Any]] = []
    for item in normal["entries"]:
        path = item["path"]
        data = item["content"]
        payload[path] = data
        entries.append({key: item[key] for key in ("path", "sha256", "bytes", "source_type", "observed_at", "resource", "scope", "principal")})
    manifest: Dict[str, Any] = {
        "format": "llm-brain-openclaw-stage.v1",
        "adapter": "openclaw",
        "profile_id": normal["profile_id"],
        "openclaw_version": normal["version"],
        "schema_version": SCHEMA_VERSION,
        "okf_version": OKF_VERSION,
        "project_id": project_id,
        "scope": normal["scope"],
        "principal": normal["principal"],
        "entries": entries,
        "external_observation": True,
        "canonical_write": False,
        "reciprocal_write": False,
    }
    return manifest, payload


def do_openclaw(args: argparse.Namespace) -> Dict[str, Any]:
    profile, base = openclaw_profile_source(Path(args.input))
    normal = normalise_openclaw(profile, base, args.scope, args.principal)
    manifest, payload = openclaw_manifest(normal, args.project_id)
    project_dir = Path(args.project_dir) if args.project_dir else None
    if args.action == "inspect":
        result = dict(manifest)
        result["status"] = "ok"
        result["entries"] = [item for item in result["entries"]]
        if args.output:
            out = Path(args.output).expanduser().resolve()
            output_is_canonical(out, project_dir)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(canonical_json(result))
        return result
    if not args.output:
        error("OpenClaw stage requires --output DIR", 64)
    if not args.project_dir:
        error("OpenClaw stage requires project context for canonical protection", 64)
    output = Path(args.output).expanduser()
    if output.is_symlink():
        error("OpenClaw stage output is symlinked: %s" % output, 73)
    output = output.resolve()
    output_is_canonical(output, project_dir)
    if output.exists():
        if output.is_symlink() or not output.is_dir() or (output / "manifest.json").is_symlink() or not (output / "manifest.json").is_file() or read_bounded(output / "manifest.json") != canonical_json(manifest):
            error("OpenClaw stage conflict: %s" % output, 73)
        validate_stage_metadata(
            output / "stage.json",
            {
                "format": "llm-brain-external-observation-stage.v1",
                "adapter": "openclaw",
                "manifest_sha256": sha256_bytes(canonical_json(manifest)),
            },
            "OpenClaw stage",
        )
        validate_stage_tree(output, set(payload), "OpenClaw stage")
        for rel, data in payload.items():
            target = output / "observations" / rel
            if target.is_symlink() or not target.is_file() or sha256_file(target) != sha256_bytes(data):
                error("OpenClaw stage file conflict: %s" % rel, 73)
        return {"status": "idempotent", "adapter": "openclaw", "profile_id": normal["profile_id"], "openclaw_version": OPENCLAW_VERSION, "entries": len(payload), "output": str(output), "canonical_write": False, "reciprocal_write": False, "external_observation": True}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".openclaw-stage.", dir=str(output.parent)))
    try:
        (temporary / "observations").mkdir()
        (temporary / "manifest.json").write_bytes(canonical_json(manifest))
        (temporary / "stage.json").write_bytes(canonical_json({"format": "llm-brain-external-observation-stage.v1", "adapter": "openclaw", "canonical_write": False, "reciprocal_write": False, "external_observation": True, "manifest_sha256": sha256_bytes(canonical_json(manifest))}))
        for rel, data in payload.items():
            target = temporary / "observations" / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        os.replace(str(temporary), str(output))
    finally:
        if temporary.exists():
            shutil.rmtree(str(temporary))
    return {"status": "staged", "adapter": "openclaw", "profile_id": normal["profile_id"], "openclaw_version": OPENCLAW_VERSION, "entries": len(payload), "output": str(output), "canonical_write": False, "reciprocal_write": False, "external_observation": True}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    export = sub.add_parser("export")
    export.add_argument("--project-dir", required=True)
    export.add_argument("--project-id", required=True)
    export.add_argument("--scope", choices=("project", "principal"), default="project")
    export.add_argument("--principal", default="")
    export.add_argument("--review", default="")
    export.add_argument("--output")
    imp = sub.add_parser("import")
    imp.add_argument("--archive", required=True)
    imp.add_argument("--project-id")
    imp.add_argument("--project-dir")
    imp.add_argument("--output")
    imp.add_argument("--dry-run", action="store_true")
    imp.add_argument("--stage", action="store_true")
    oc = sub.add_parser("openclaw")
    oc.add_argument("action", choices=("inspect", "stage"))
    oc.add_argument("--input", required=True)
    oc.add_argument("--project-id")
    oc.add_argument("--scope", choices=("project", "principal"))
    oc.add_argument("--principal")
    oc.add_argument("--output")
    oc.add_argument("--project-dir")
    return root


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "export":
            result = do_replication_export(args)
        elif args.command == "import":
            result = do_replication_import(args)
        else:
            result = do_openclaw(args)
    except LaneError as exc:
        print("llm-brain: %s" % exc, file=sys.stderr)
        return exc.code
    except (OSError, tarfile.TarError) as exc:
        print("llm-brain: replication I/O failure: %s" % exc, file=sys.stderr)
        return 73
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
