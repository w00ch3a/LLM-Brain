#!/usr/bin/env python3
"""Strict OKF v0.2 parsing and schema-3 migration support for LLM-Brain."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
import time
import copy
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised by upgrade bootstrap tests
    raise SystemExit(
        "memthena: PyYAML is unavailable; run `llm-brain upgrade check` "
        "and install the hash-locked OKF runtime"
    ) from exc


OKF_VERSION = "0.2"
ACTOR_RE = re.compile(
    r"^(?:human:[^\s:]+|process:[^\s:]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.:+-]+)$"
)
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FRONTMATTER_RE = re.compile(
    r"\A---[ \t]*\r?\n(?P<header>.*?)^---[ \t]*\r?\n",
    re.MULTILINE | re.DOTALL,
)
RESERVED = {"index.md", "log.md"}
CODE_ANCHOR_RE = re.compile(r"^[^@\s][^@]*@[0-9a-fA-F]{7,40}$")


# Same detector as bin/llm-brain secret_scan_file (grep -Ei, line based).
SECRET_BEARING = re.compile(
    rb'-----BEGIN [A-Z ]*PRIVATE KEY-----|(?<![A-Za-z0-9_])sk-(proj-)?[A-Za-z0-9_-]{16,}|(?<![A-Za-z0-9_])AKIA[0-9A-Z]{16}|(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,}'
    rb'|(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}|(api[_-]?key|secret|password|token)[ \t\r\f\v]*[:=][ \t\r\f\v]*"?[A-Za-z0-9_./+=-]{16,}',
    re.I,
)


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader variant that rejects duplicate mapping keys."""


def _construct_mapping(
    loader: UniqueKeyLoader, node: yaml.nodes.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable key",
                key_node.start_mark,
            ) from exc
        if duplicate:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


class OkfError(ValueError):
    pass


def read_text(path: Path) -> str:
    try:
        return path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as exc:
        raise OkfError("not valid UTF-8") from exc
    except OSError as exc:
        raise OkfError(str(exc)) from exc


def split_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    text = read_text(path)
    return split_frontmatter_text(text)


def split_frontmatter_text(text: str) -> tuple[dict[str, Any], str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        raise OkfError("missing or unterminated YAML frontmatter")
    try:
        metadata = yaml.load(match.group("header"), Loader=UniqueKeyLoader)
    except yaml.YAMLError as exc:
        raise OkfError(f"malformed YAML: {exc}") from exc
    if not isinstance(metadata, dict):
        raise OkfError("frontmatter must be a YAML mapping")
    if not all(isinstance(key, str) for key in metadata):
        raise OkfError("frontmatter keys must be strings")
    return metadata, text[match.end() :]


def dump_document(path: Path, metadata: dict[str, Any], body: str) -> None:
    header = yaml.safe_dump(
        metadata,
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
        width=1000,
    )
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(f"---\n{header}---\n{body}", encoding="utf-8")
    temporary.replace(path)


def scalar_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (str, int, float)):
        return str(value)
    return json.dumps(value, separators=(",", ":"), default=scalar_text)


def valid_date(value: Any) -> bool:
    text = scalar_text(value)
    if not DATE_RE.fullmatch(text):
        return False
    try:
        dt.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def valid_datetime(value: Any) -> bool:
    if isinstance(value, dt.datetime):
        return value.tzinfo is not None
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def valid_actor(value: Any) -> bool:
    return isinstance(value, str) and bool(ACTOR_RE.fullmatch(value))


def concept_issues(metadata: dict[str, Any], body: str) -> list[str]:
    issues: list[str] = []
    concept_type = metadata.get("type")
    if not isinstance(concept_type, str) or not concept_type.strip():
        issues.append("missing non-empty type")

    generated = metadata.get("generated")
    if generated is not None:
        if not isinstance(generated, dict):
            issues.append("generated must be a mapping")
        else:
            if not valid_actor(generated.get("by")):
                issues.append("generated.by is not a valid actor")
            if "at" in generated and not valid_datetime(generated["at"]):
                issues.append("generated.at is not an ISO 8601 datetime with timezone")

    verified = metadata.get("verified")
    if verified is not None:
        events = verified if isinstance(verified, list) else [verified]
        if not events or not all(isinstance(event, dict) for event in events):
            issues.append("verified must be a mapping or non-empty list of mappings")
        else:
            for index, event in enumerate(events):
                if not valid_actor(event.get("by")):
                    issues.append(f"verified[{index}].by is not a valid actor")
                if not valid_datetime(event.get("at")):
                    issues.append(
                        f"verified[{index}].at is not an ISO 8601 datetime with timezone"
                    )

    sources = metadata.get("sources")
    if sources is not None:
        if not isinstance(sources, list):
            issues.append("sources must be a list")
        else:
            for index, source in enumerate(sources):
                if not isinstance(source, dict):
                    issues.append(f"sources[{index}] must be a mapping")
                elif not isinstance(source.get("resource"), str) or not source[
                    "resource"
                ].strip():
                    issues.append(f"sources[{index}].resource must be non-empty")
                elif "usage_count" in source and (
                    not isinstance(source["usage_count"], int)
                    or isinstance(source["usage_count"], bool)
                    or source["usage_count"] < 0
                ):
                    issues.append(f"sources[{index}].usage_count must be non-negative")
                elif "last_modified" in source and not valid_date(
                    source["last_modified"]
                ):
                    issues.append(
                        f"sources[{index}].last_modified must be YYYY-MM-DD"
                    )

    usage_window = metadata.get("usage_window")
    if usage_window is not None and (
        not isinstance(usage_window, dict)
        or not valid_date(usage_window.get("from"))
        or not valid_date(usage_window.get("to"))
    ):
        issues.append("usage_window must contain YYYY-MM-DD from and to dates")

    status = metadata.get("status")
    if status is not None and status not in {"draft", "stable", "deprecated"}:
        issues.append("status must be draft, stable or deprecated")

    if "stale_after" in metadata and not valid_date(metadata["stale_after"]):
        issues.append("stale_after must be YYYY-MM-DD")

    for field in (
        "brain_observed_at",
        "brain_valid_from",
        "brain_valid_to",
        "brain_last_verified_at",
    ):
        if field in metadata and not valid_datetime(metadata[field]):
            issues.append(f"{field} must be an ISO 8601 datetime with timezone")
    valid_from = metadata.get("brain_valid_from")
    valid_to = metadata.get("brain_valid_to")
    if valid_from is not None and valid_to is not None:
        try:
            start = dt.datetime.fromisoformat(scalar_text(valid_from).replace("Z", "+00:00"))
            end = dt.datetime.fromisoformat(scalar_text(valid_to).replace("Z", "+00:00"))
            if start >= end:
                issues.append("brain_valid_from must be earlier than brain_valid_to")
        except ValueError:
            pass
    if "brain_version_of" in metadata and (
        not isinstance(metadata["brain_version_of"], str)
        or not metadata["brain_version_of"].strip()
    ):
        issues.append("brain_version_of must be a non-empty reference")
    derived_from = metadata.get("brain_derived_from")
    if derived_from is not None:
        values = derived_from if isinstance(derived_from, list) else [derived_from]
        if not values or not all(isinstance(value, str) and value.strip() for value in values):
            issues.append("brain_derived_from must contain non-empty references")
    state_key = metadata.get("brain_state_key")
    if state_key is not None and (not isinstance(state_key, str) or not state_key.strip()):
        issues.append("brain_state_key must be a non-empty string")
    depends_on = metadata.get("brain_depends_on")
    if depends_on is not None:
        values = depends_on if isinstance(depends_on, list) else [depends_on]
        if not values or not all(isinstance(value, str) and value.strip() for value in values):
            issues.append("brain_depends_on must contain non-empty references")
    for field in (
        "brain_supersedes",
        "brain_conflicts",
        "brain_supports",
    ):
        value = metadata.get(field)
        if value is not None:
            values = value if isinstance(value, list) else [value]
            if not values or not all(
                isinstance(item, str) and item.strip() for item in values
            ):
                issues.append(f"{field} must contain non-empty references")
    brain_paths = metadata.get("brain_paths")
    if brain_paths is not None:
        values = brain_paths if isinstance(brain_paths, list) else [brain_paths]
        if not values or not all(
            isinstance(item, str) and item.strip() and not item.strip().startswith("/")
            and ".." not in PurePosixPath(item.strip()).parts
            for item in values
        ):
            issues.append("brain_paths must contain non-empty relative path globs")
    anchors = metadata.get("brain_code_anchors")
    if anchors is not None:
        values = anchors if isinstance(anchors, list) else [anchors]
        if not values or not all(
            isinstance(item, str) and CODE_ANCHOR_RE.fullmatch(item.strip())
            and not item.strip().startswith("/")
            and ".." not in PurePosixPath(item.strip().rsplit("@", 1)[0]).parts
            for item in values
        ):
            issues.append("brain_code_anchors must contain relative path@commit anchors")
    required_bindings = metadata.get("brain_required_bindings")
    if required_bindings is not None and (
        not isinstance(required_bindings, str) or not required_bindings.strip()
    ):
        issues.append("brain_required_bindings must be a non-empty string")
    commitment = metadata.get("brain_commitment_action")
    if commitment is not None and commitment not in {
        "persist", "use-now", "reverify", "ask", "quarantine", "undetermined"
    }:
        issues.append("brain_commitment_action is not recognised")
    if "brain_reverify_after" in metadata and not valid_datetime(metadata["brain_reverify_after"]):
        issues.append("brain_reverify_after must be an ISO 8601 datetime with timezone")
    if "brain_authority_origin" in metadata and metadata["brain_authority_origin"] not in {
        "human-directive",
        "repository",
        "runtime-proof",
        "approved-canonical",
        "source",
        "provider",
        "external-observation",
        "unknown",
    }:
        issues.append("brain_authority_origin is not a recognised authority origin")

    if concept_type == "Attested Computation":
        if not isinstance(metadata.get("runtime"), str) or not metadata["runtime"].strip():
            issues.append("Attested Computation requires a non-empty runtime")
        parameters = metadata.get("parameters")
        if parameters is not None:
            if not isinstance(parameters, list):
                issues.append("parameters must be a list")
            else:
                for index, parameter in enumerate(parameters):
                    if not isinstance(parameter, dict):
                        issues.append(f"parameters[{index}] must be a mapping")
                        continue
                    if not isinstance(parameter.get("name"), str) or not parameter[
                        "name"
                    ].strip():
                        issues.append(f"parameters[{index}].name must be non-empty")
                    if not isinstance(parameter.get("type"), str) or not parameter[
                        "type"
                    ].strip():
                        issues.append(f"parameters[{index}].type must be non-empty")
                    if not isinstance(parameter.get("required"), bool):
                        issues.append(f"parameters[{index}].required must be boolean")
        for family in ("executor", "attester"):
            value = metadata.get(family)
            if value is not None and (
                not isinstance(value, dict)
                or not isinstance(value.get("resource"), str)
                or not value["resource"].strip()
            ):
                issues.append(f"{family} must contain a non-empty resource")
        computation = metadata.get("computation")
        if computation is not None and (
            not isinstance(computation, str) or not computation.strip()
        ):
            issues.append("computation must be a non-empty path")
        if computation is None and not re.search(
            r"(?m)^# Computation[ \t]*\r?$", body
        ):
            issues.append(
                "Attested Computation needs computation or a # Computation section"
            )
    return issues


def parse_reserved_frontmatter(path: Path) -> tuple[dict[str, Any] | None, str]:
    text = read_text(path)
    if not text.startswith("---"):
        return None, text
    return split_frontmatter(path)


def reserved_issues(path: Path, root: Path) -> list[str]:
    issues: list[str] = []
    metadata, body = parse_reserved_frontmatter(path)
    relative = path.relative_to(root)
    if path.name == "index.md":
        if relative == Path("index.md"):
            if metadata != {"okf_version": OKF_VERSION}:
                issues.append(
                    'root index frontmatter must contain only okf_version: "0.2"'
                )
            if not re.search(r"\[[^\]]+\]\([^)]+\)", body):
                issues.append("root index must contain progressive-disclosure links")
        elif metadata is not None:
            issues.append("non-root index must not contain frontmatter")
    else:
        if metadata is not None:
            issues.append("log must not contain frontmatter")
        dates: list[str] = []
        for heading in re.findall(r"(?m)^##[ \t]+([^\r\n]+)", body):
            if not valid_date(heading.strip()):
                issues.append(f"invalid log date heading {heading!r}")
            else:
                dates.append(heading.strip())
        if dates != sorted(dates, reverse=True):
            issues.append("log date headings must be newest first")
    return issues


def validate_bundle(root: Path, cache: "RecordCache | None" = None) -> tuple[list[tuple[Path, str]], int]:
    issues: list[tuple[Path, str]] = []
    concepts = 0
    if not root.is_dir():
        return [(root, "bundle directory missing")], concepts
    for path in sorted(root.rglob("*.md")):
        if path.name in RESERVED:
            try:
                current = reserved_issues(path, root)
            except OkfError as exc:
                current = [str(exc)]
        else:
            concepts += 1
            try:
                metadata, body = _cached_frontmatter(path, cache)
                current = concept_issues(metadata, body)
            except OkfError as exc:
                current = [str(exc)]
        issues.extend((path.relative_to(root), issue) for issue in current)
    return issues, concepts


def _cached_frontmatter(path: Path, cache: "RecordCache | None") -> tuple[dict[str, Any], str]:
    """split_frontmatter(path) through the stat-checked record cache when one
    is given; symlinks, unreadable files and anything outside the cache root
    take the original path, so errors and messages are unchanged."""
    if cache is not None and cache.enabled:
        try:
            full = os.path.join(os.path.realpath(path.parent), path.name)
            rel = os.path.relpath(full, cache.root)
            if not rel.startswith(".." + os.sep) and rel != ".." and not path.is_symlink():
                return RecordCache.metadata_body(cache.read(full, rel.replace(os.sep, "/")))
        except (OSError, ValueError):
            pass
    return split_frontmatter(path)


def trust_tier(metadata: dict[str, Any]) -> str:
    verified = metadata.get("verified")
    if verified is None:
        return "unverified"
    events = verified if isinstance(verified, list) else [verified]
    if any(
        isinstance(event, dict)
        and isinstance(event.get("by"), str)
        and event["by"].startswith("human:")
        for event in events
    ):
        return "human-reviewed"
    return "machine-confirmed"


def freshness(metadata: dict[str, Any], today: dt.date | None = None) -> str:
    value = metadata.get("stale_after")
    if value is None:
        return "unspecified"
    if not valid_date(value):
        return "invalid"
    current = today or dt.datetime.now(dt.timezone.utc).date()
    return "stale" if current >= dt.date.fromisoformat(scalar_text(value)) else "fresh"


def extract_citations(
    body: str,
) -> tuple[str, list[dict[str, str]], list[str]]:
    lines = body.splitlines(keepends=True)
    start: int | None = None
    end = len(lines)
    for index, line in enumerate(lines):
        if re.fullmatch(r"# Citations[ \t]*\r?\n?", line):
            start = index
            continue
        if start is not None and index > start and re.match(r"^#(?!#)[ \t]+", line):
            end = index
            break
    if start is None:
        return body, [], []
    sources: list[dict[str, str]] = []
    scopes: list[str] = []
    for line in lines[start + 1 : end]:
        text = line.strip()
        if not text:
            continue
        item = re.sub(r"^[-*+][ \t]+", "", text)
        match = re.fullmatch(r"\[([^\]]+)\]\(([^)]+)\)", item)
        if match:
            sources.append({"resource": match.group(2), "title": match.group(1)})
        elif re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:[^\s]+$", item):
            sources.append({"resource": item})
        else:
            scopes.append(item)
    replacement = lines[:start] + lines[end:]
    while replacement and not replacement[-1].strip():
        replacement.pop()
    return "".join(replacement).rstrip() + "\n", sources, scopes


def status_for(metadata: dict[str, Any]) -> str:
    if metadata.get("status") in {"draft", "stable", "deprecated"}:
        return str(metadata["status"])
    if metadata.get("type") == "Retraction":
        return "stable"
    state = scalar_text(
        metadata.get("brain_review_state", metadata.get("review_state", ""))
    )
    if state == "approved":
        return "stable"
    if state in {"proposed", "draft", "needs-validation"}:
        return "draft"
    if state in {"rejected", "superseded"}:
        return "deprecated"
    return "stable"


def migrate_metadata(
    metadata: dict[str, Any], body: str, actor: str, at: str, hint: str | None
) -> tuple[dict[str, Any], str]:
    migrated = dict(metadata)
    if not isinstance(migrated.get("type"), str) or not migrated["type"].strip():
        if not hint:
            raise OkfError("cannot derive missing concept type")
        migrated["type"] = hint
    migrated["status"] = status_for(migrated)

    legacy_timestamp = migrated.pop("timestamp", None)
    if "generated" not in migrated:
        migrated["generated"] = {"by": actor, "at": at}
        if legacy_timestamp is not None:
            migrated["brain_legacy_timestamp"] = scalar_text(legacy_timestamp)

    new_body, citations, citation_scopes = extract_citations(body)
    if citations:
        existing = migrated.get("sources")
        if existing is None:
            migrated["sources"] = citations
        elif isinstance(existing, list):
            migrated["sources"] = existing + citations
    if citation_scopes:
        existing_scopes = migrated.get("brain_legacy_citation_scopes")
        if isinstance(existing_scopes, list):
            migrated["brain_legacy_citation_scopes"] = (
                existing_scopes + citation_scopes
            )
        else:
            migrated["brain_legacy_citation_scopes"] = citation_scopes

    if "verified" not in migrated:
        reviewer = migrated.get("brain_reviewed_by")
        reviewed_at = migrated.get("brain_reviewed_at")
        if valid_actor(reviewer) and valid_datetime(reviewed_at):
            migrated["verified"] = {"by": reviewer, "at": scalar_text(reviewed_at)}
    return migrated, new_body


def concept_hint(path: Path, root: Path) -> str | None:
    relative = path.relative_to(root)
    if len(relative.parts) <= 1:
        return None
    return {
        "claims": "Claim",
        "procedures": "Procedure",
        "references": "Reference",
        "topics": "Topic",
        "retractions": "Retraction",
        "computations": "Attested Computation",
    }.get(relative.parts[0])


def migrate_log(path: Path, migration_date: str) -> None:
    text = read_text(path)
    preamble: list[str] = []
    groups: dict[str, list[str]] = {}
    current: str | None = None
    for line in text.splitlines():
        match = re.match(r"^-\s+(\d{4}-\d{2}-\d{2}):\s*(.*)$", line)
        if match:
            current = match.group(1)
            groups.setdefault(current, []).append(f"* **Update**: {match.group(2)}")
            continue
        heading = re.match(r"^##[ \t]+(\d{4}-\d{2}-\d{2})[ \t]*$", line)
        if heading:
            current = heading.group(1)
            groups.setdefault(current, [])
            continue
        if current is None:
            preamble.append(line)
        elif line or groups[current]:
            groups[current].append(line)
    if not groups:
        groups[migration_date] = ["* **Migration**: Converted to OKF v0.2."]
    output = preamble
    while output and not output[-1]:
        output.pop()
    for date in sorted(groups, reverse=True):
        entries = groups[date]
        while entries and not entries[0]:
            entries.pop(0)
        while entries and not entries[-1]:
            entries.pop()
        output.extend(["", f"## {date}", *entries])
    path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")


def index_body(root: Path) -> str:
    lines = ["# LLM-Brain Knowledge", "", "## Project", ""]
    if (root / "project.md").is_file():
        lines.append("* [Project](project.md) - Project identity and scope.")
    groups: list[tuple[str, str]] = []
    for directory in sorted(path for path in root.iterdir() if path.is_dir()):
        if any(
            child.suffix == ".md" and child.name not in RESERVED
            for child in directory.rglob("*.md")
        ):
            groups.append((directory.name.replace("-", " ").title(), directory.name))
    if groups:
        lines.extend(["", "## Knowledge", ""])
        lines.extend(
            f"* [{title}]({name}/) - {title} concepts." for title, name in groups
        )
    return "\n".join(lines).rstrip() + "\n"


def migrate_bundle(root: Path, project_id: str, title: str, actor: str, at: str) -> None:
    if not valid_actor(actor):
        raise OkfError(f"invalid migration actor: {actor}")
    if not valid_datetime(at):
        raise OkfError(f"invalid migration datetime: {at}")
    index = root / "index.md"
    old_metadata: dict[str, Any] = {}
    old_body = ""
    if index.is_file():
        parsed, old_body = parse_reserved_frontmatter(index)
        old_metadata = parsed or {}
    project = root / "project.md"
    if not project.exists():
        project_metadata = dict(old_metadata)
        project_metadata.pop("okf_version", None)
        project_metadata["type"] = "Project"
        project_metadata.setdefault("title", title)
        project_metadata.setdefault("brain_project_id", project_id)
        project_metadata["brain_schema_version"] = 3
        project_metadata, project_body = migrate_metadata(
            project_metadata,
            old_body or f"# {title}\n\nCanonical filesystem-first durable memory.\n",
            actor,
            at,
            "Project",
        )
        dump_document(project, project_metadata, project_body)
    else:
        metadata, body = split_frontmatter(project)
        metadata, body = migrate_metadata(metadata, body, actor, at, "Project")
        metadata["brain_schema_version"] = 3
        dump_document(project, metadata, body)

    index.write_text(
        f'---\nokf_version: "{OKF_VERSION}"\n---\n{index_body(root)}',
        encoding="utf-8",
    )
    log = root / "log.md"
    if log.exists():
        migrate_log(log, at[:10])
    else:
        log.write_text(
            f"# Directory Update Log\n\n## {at[:10]}\n"
            "* **Migration**: Converted to OKF v0.2.\n",
            encoding="utf-8",
        )

    for path in sorted(root.rglob("*.md")):
        if path.name in RESERVED or path == project:
            continue
        metadata, body = split_frontmatter(path)
        metadata, body = migrate_metadata(
            metadata, body, actor, at, concept_hint(path, root)
        )
        metadata["brain_schema_version"] = 3
        dump_document(path, metadata, body)
    issues, _ = validate_bundle(root)
    if issues:
        rendered = "; ".join(f"{path}: {issue}" for path, issue in issues[:10])
        raise OkfError(f"post-migration OKF validation failed: {rendered}")


def audit_counts(root: Path) -> dict[str, int]:
    counts = {
        "malformed_frontmatter": 0,
        "missing_types": 0,
        "invalid_reserved": 0,
        "legacy_timestamps": 0,
        "legacy_citations": 0,
        "invalid_standard_fields": 0,
    }
    for path in sorted(root.rglob("*.md")) if root.is_dir() else []:
        if path.name in RESERVED:
            try:
                counts["invalid_reserved"] += len(reserved_issues(path, root))
            except OkfError:
                counts["invalid_reserved"] += 1
                counts["malformed_frontmatter"] += 1
            continue
        try:
            metadata, body = split_frontmatter(path)
        except OkfError:
            counts["malformed_frontmatter"] += 1
            continue
        if not isinstance(metadata.get("type"), str) or not metadata["type"].strip():
            counts["missing_types"] += 1
        if "timestamp" in metadata:
            counts["legacy_timestamps"] += 1
        if re.search(r"(?m)^# Citations[ \t]*\r?$", body):
            counts["legacy_citations"] += 1
        counts["invalid_standard_fields"] += len(concept_issues(metadata, body))
        if not isinstance(metadata.get("type"), str) or not metadata["type"].strip():
            counts["invalid_standard_fields"] -= 1
    return counts


def command_validate(args: argparse.Namespace) -> int:
    root = Path(args.bundle)
    # Share the project's record cache (rel paths "okf/...") so a lint on a
    # NAS vault stats records instead of re-reading every one.
    cache = None
    if root.name == "okf" and root.is_dir() and not root.is_symlink():
        cache = RecordCache(root.parent)
    issues, concepts = validate_bundle(root, cache)
    if cache is not None:
        cache.save()
    for path, issue in issues:
        print(f"okf:error path={path.as_posix()} issue={issue}")
    print(
        f"okf bundle={root} version={OKF_VERSION} concepts={concepts} "
        f"errors={len(issues)}"
    )
    return 1 if issues else 0


def facts_metadata_text(metadata: dict[str, Any]) -> str:
    generated = metadata.get("generated")
    generated_at = generated.get("at") if isinstance(generated, dict) else ""
    values = [
        scalar_text(metadata.get("type")),
        scalar_text(metadata.get("title")),
        scalar_text(metadata.get("status", "stable")),
        trust_tier(metadata),
        freshness(metadata),
        scalar_text(generated_at),
        scalar_text(metadata.get("stale_after")),
        scalar_text(len(metadata.get("sources", [])))
        if isinstance(metadata.get("sources", []), list)
        else "invalid",
        scalar_text(metadata.get("runtime")),
    ]
    return "\t".join(
        (value or "none").replace("\t", " ").replace("\n", " ")
        for value in values
    )


def facts_text(path: Path) -> str:
    metadata, _ = split_frontmatter(path)
    return facts_metadata_text(metadata)


def command_facts(args: argparse.Namespace) -> int:
    print(facts_text(Path(args.file)))
    return 0


def command_facts_batch(args: argparse.Namespace) -> int:
    try:
        raw_paths = Path(args.paths_file).read_bytes()
    except OSError as exc:
        raise OkfError(str(exc)) from exc
    if raw_paths and not raw_paths.endswith(b"\n"):
        raise OkfError("facts path list is not newline-terminated")
    paths = [os.fsdecode(line) for line in raw_paths.splitlines()]
    project_root = Path(os.path.abspath(args.project_root))
    snapshot_root = Path(os.path.abspath(args.snapshot_root))
    rows: list[str] = []
    for path in paths:
        source = Path(os.path.abspath(path))
        try:
            relative = source.relative_to(project_root)
        except ValueError as exc:
            raise OkfError("facts path is outside project root") from exc
        try:
            source_fd = os.open(os.fspath(source), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError as exc:
            raise OkfError(str(exc)) from exc
        try:
            with os.fdopen(source_fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise OkfError("facts source is not a regular file")
                raw = stream.read()
        except OSError as exc:
            raise OkfError(str(exc)) from exc
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise OkfError("not valid UTF-8") from exc
        metadata, _ = split_frontmatter_text(text)
        snapshot = snapshot_root / relative
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        try:
            snapshot_fd = os.open(
                os.fspath(snapshot),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(snapshot_fd, "wb") as stream:
                stream.write(raw)
        except OSError as exc:
            raise OkfError(str(exc)) from exc
        rows.append(hashlib.sha256(raw).hexdigest() + "\t" + facts_metadata_text(metadata))
    for row in rows:
        print(row)
    return 0


def command_field(args: argparse.Namespace) -> int:
    metadata, _ = split_frontmatter(Path(args.file))
    value: Any = metadata
    for part in args.key.split("."):
        if not isinstance(value, dict) or part not in value:
            return 0
        value = value[part]
    print(scalar_text(value))
    return 0


def command_facts_list(args: argparse.Namespace) -> int:
    """`facts` for every listed path, one "PATH<TAB>FACTS" line each, so a
    search renders its result rows with one interpreter start.  Any failure
    or multi-line value fails the whole call; callers then fall back to
    per-file `facts`."""
    try:
        paths = Path(args.paths_file).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise OkfError(f"invalid paths file: {exc}") from exc
    rows = []
    for raw_path in paths:
        if not raw_path:
            continue
        text = facts_text(Path(raw_path))
        if "\n" in text or "\n" in raw_path or "\t" in raw_path:
            raise OkfError("facts value is not a single line")
        rows.append(raw_path + "\t" + text)
    for row in rows:
        print(row)
    return 0


def command_valid_batch(args: argparse.Namespace) -> int:
    """One line per input path: "1<TAB>path" when `field PATH type` would
    succeed, "0<TAB>path" when it would fail.  Lets a search validate every
    candidate with one interpreter start instead of one per record."""
    try:
        paths = Path(args.paths_file).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise OkfError(f"invalid paths file: {exc}") from exc
    for raw_path in paths:
        if not raw_path:
            continue
        ok = "1"
        try:
            metadata, _ = split_frontmatter(Path(raw_path))
            if isinstance(metadata, dict) and "type" in metadata:
                scalar_text(metadata["type"])
        except Exception:  # noqa: BLE001 - any failure means "not valid", as with `field`
            ok = "0"
        print(ok + "\t" + raw_path)
    return 0


# --- Local, derived read cache (Memthena speed work) -------------------------
# A per-machine mirror of canonical records keyed on (size, mtime_ns,
# ctime_ns, inode).  It lives on local disk (never in the vault), is never
# authoritative and can be deleted at any time.  A hit costs one stat and no
# read, which is what makes NAS (SMB/NFS) brains fast.  Entries whose mtime is
# within RECORD_CACHE_RACY_NS of the moment they were cached are not trusted
# (git's "racy clean" rule), so a write that lands inside a coarse timestamp
# tick is always re-read.  Every writer replaces files atomically, which also
# changes the inode, so other machines' writes on a shared NAS are seen as
# misses.  Disable with LLM_BRAIN_CACHE=0 or MEMTHENA_CACHE=0.
RECORD_CACHE_FORMAT = 1
RECORD_CACHE_RACY_NS = 2_000_000_000


def record_cache_enabled() -> bool:
    for name in ("MEMTHENA_CACHE", "LLM_BRAIN_CACHE"):
        if os.environ.get(name, "").strip().lower() in ("0", "off", "false", "no"):
            return False
    return True


TRUST_SECONDS_DEFAULT = 0  # opt-in; bulk folder stat made the window unnecessary


def _trust_seconds() -> int:
    """MEMTHENA_NAS_TRUST_SECONDS (alias LLM_BRAIN_NAS_TRUST_SECONDS): opt-in, default 0 (off).
    Anything that is not a whole number disables it too (fail safe)."""
    for name in ("MEMTHENA_NAS_TRUST_SECONDS", "LLM_BRAIN_NAS_TRUST_SECONDS"):
        value = os.environ.get(name)
        if value is not None and value.strip() != "":
            value = value.strip()
            return int(value) if value.isdigit() else 0
    return TRUST_SECONDS_DEFAULT


def _change_token(root: str, extra_dirs: Iterable[str] = ()) -> list[Any]:
    """(dir, mtime_ns, ctime_ns, inode) for the project folder, every folder
    under okf/, every other folder holding a cached record, the vault's
    .locks/ folder and the audit log.  Every CLI write (and so every Hermes
    and MCP write, which go through the CLI) takes the project lock, which
    creates and removes a folder in .locks/, and records are written by
    atomic rename, so any write changes the token at once.  An in-place edit
    by hand does not, which is why trust is opt-in and time-boxed."""
    token: list[Any] = []
    stack = [root]
    okf_root = os.path.join(root, "okf")
    projects = os.path.dirname(root)
    locks = os.path.join(os.path.dirname(projects), ".locks") if os.path.basename(projects) == "projects" else None
    for extra in sorted(set(extra_dirs)) + ([locks] if locks else []):
        try:
            st = os.lstat(extra)
            token.append((os.path.relpath(extra, root), st.st_mtime_ns, st.st_ctime_ns, st.st_ino))
        except OSError:
            token.append((os.path.relpath(extra, root), None))
    while stack:
        current = stack.pop()
        try:
            st = os.lstat(current)
        except OSError:
            token.append((current, None)); continue
        token.append((os.path.relpath(current, root), st.st_mtime_ns, st.st_ctime_ns, st.st_ino))
        if current == root:
            stack.append(okf_root)
            for extra in ("audit.v2.tsv", os.path.join("audit", "audit.v2.tsv")):
                try:
                    st = os.lstat(os.path.join(root, extra))
                    token.append((extra, st.st_mtime_ns, st.st_size))
                except OSError:
                    pass
            continue
        try:
            with os.scandir(current) as entries:
                stack.extend(sorted(e.path for e in entries if e.is_dir(follow_symlinks=False)))
        except OSError:
            token.append((current, "unreadable"))
    return token


# --- Bulk folder stat (macOS getattrlistbulk) --------------------------------
# On an SMB share every lstat is a network round trip once the client's
# attribute cache has gone cold (about 30 s idle): about 4 ms each, 20 s for
# 5,000 records.  One getattrlistbulk enumeration of the folder returns the
# same (size, mtime, ctime, inode, device) for every entry from SMB
# QUERY_DIRECTORY in a few round trips (about 2.5 s for 5,000 records).  It is
# the same per-file freshness check, just batched per folder: values match
# lstat exactly (checked on all 5,000 records of the NAS bench vault).  Used
# only by read-only callers, falls back to lstat on any doubt, and is off
# with MEMTHENA_BULK_STAT=0 (alias LLM_BRAIN_BULK_STAT=0).
BULK_STAT_MIN_READS = 8


def bulk_stat_enabled() -> bool:
    for name in ("MEMTHENA_BULK_STAT", "LLM_BRAIN_BULK_STAT"):
        value = os.environ.get(name)
        if value is not None and value.strip() != "":
            return value.strip().lower() not in ("0", "off", "false", "no")
    return sys.platform == "darwin"


class _BulkStat:
    __slots__ = ("st_size", "st_mtime_ns", "st_ctime_ns", "st_ino", "st_dev")

    def __init__(self, size: int, mtime_ns: int, ctime_ns: int, ino: int, dev: int) -> None:
        self.st_size, self.st_mtime_ns, self.st_ctime_ns, self.st_ino, self.st_dev = size, mtime_ns, ctime_ns, ino, dev


_GETATTRLISTBULK: Any = None


def _bulk_scan(folder: str) -> dict[str, _BulkStat] | None:
    """{name: stat} for the regular files in FOLDER, or None when unsupported
    or anything looks wrong (the caller then uses lstat per file)."""
    global _GETATTRLISTBULK
    import ctypes
    import ctypes.util
    import struct

    if _GETATTRLISTBULK is None:
        _GETATTRLISTBULK = False
        if sys.platform == "darwin":
            try:
                fn = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True).getattrlistbulk
                fn.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64]
                fn.restype = ctypes.c_int
                _GETATTRLISTBULK = fn
            except (OSError, AttributeError):
                pass
    if not _GETATTRLISTBULK:
        return None

    class AttrList(ctypes.Structure):
        _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                    ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                    ("forkattr", ctypes.c_uint32)]

    # name, devid, objtype, modtime, chgtime, fileid (+ error, returned set); file data length.
    need = 0x1 | 0x2 | 0x8 | 0x400 | 0x800 | 0x2000000
    attrs = AttrList(5, 0, 0x80000000 | 0x20000000 | need, 0, 0, 0x200, 0)
    try:
        fd = os.open(folder, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return None
    found: dict[str, _BulkStat] = {}
    buffer = ctypes.create_string_buffer(256 * 1024)
    try:
        while True:
            count = _GETATTRLISTBULK(fd, ctypes.byref(attrs), buffer, len(buffer), 0x8 | 0x1)  # PACK_INVAL_ATTRS|NOFOLLOW
            if count < 0:
                return None
            if count == 0:
                return found
            raw, offset = buffer.raw, 0
            for _ in range(count):
                length = struct.unpack_from("<I", raw, offset)[0]
                at = offset + 4
                returned = struct.unpack_from("<5I", raw, at); at += 20
                error = struct.unpack_from("<I", raw, at)[0]; at += 4
                name_at, name_len = struct.unpack_from("<iI", raw, at)
                name = raw[at + name_at:at + name_at + name_len].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
                at += 8
                dev = struct.unpack_from("<i", raw, at)[0] & 0xFFFFFFFF; at += 4
                kind = struct.unpack_from("<I", raw, at)[0]; at += 4
                msec, mnsec, csec, cnsec = struct.unpack_from("<qqqq", raw, at); at += 32
                ino = struct.unpack_from("<Q", raw, at)[0]; at += 8
                offset += length
                if kind != 1:  # VREG only; anything else is left to lstat
                    continue
                if error or (returned[0] & need) != need or not returned[3] & 0x200 or not length or length > len(raw):
                    return None
                size = struct.unpack_from("<q", raw, at)[0]
                found[name] = _BulkStat(size, msec * 1_000_000_000 + mnsec, csec * 1_000_000_000 + cnsec, ino, dev)
    except Exception:  # noqa: BLE001 - any surprise means "use lstat"
        return None
    finally:
        os.close(fd)


def _code_fingerprint() -> str:
    digest = hashlib.sha256()
    here = Path(__file__).resolve().parent
    for name in ("okf.py", "memory_signals.py"):
        try:
            digest.update((here / name).read_bytes())
        except OSError:
            digest.update(name.encode())
    digest.update(yaml.__version__.encode())
    return digest.hexdigest()[:16]


class _CacheUnpickler:
    """pickle.Unpickler restricted to plain data plus datetime values."""

    ALLOWED = {
        ("datetime", "date"), ("datetime", "datetime"), ("datetime", "time"),
        ("datetime", "timezone"), ("datetime", "timedelta"),
        ("builtins", "set"), ("builtins", "frozenset"), ("builtins", "bytearray"),
    }

    @classmethod
    def load(cls, stream: Any) -> Any:
        import pickle

        class Restricted(pickle.Unpickler):
            def find_class(self, module: str, name: str) -> Any:  # noqa: D401
                if (module, name) in cls.ALLOWED:
                    return super().find_class(module, name)
                raise pickle.UnpicklingError(f"blocked {module}.{name}")

        return Restricted(stream).load()


class RecordCache:
    """Stat-checked local cache of raw record bytes, sha256 and parsed YAML."""

    def __init__(self, root: Path | str, enabled: bool | None = None, trust: bool = False) -> None:
        self.root = os.path.realpath(os.fspath(root))
        self.enabled = record_cache_enabled() if enabled is None else enabled
        self.entries: dict[str, dict[str, Any]] = {}
        self.dirty = False
        # Opt-in NAS mode (read-only callers only): skip the per-record lstat
        # while the folder change token is unchanged and the last full sweep
        # is younger than LLM_BRAIN_NAS_TRUST_SECONDS.  Default off.
        self.trust_seconds = _trust_seconds() if trust else 0
        self.trusted = False
        self.token: list[Any] | None = None
        # Read-only callers only (the same ones that may use trust mode).
        self.bulk = trust and bulk_stat_enabled()
        self._bulk_maps: dict[str, dict[str, _BulkStat] | None] = {}
        self._bulk_reads: dict[str, int] = {}
        self.swept = 0.0
        self.hits = 0
        self.misses = 0
        self.path: Path | None = None
        if not self.enabled:
            return
        base = os.environ.get("LLM_BRAIN_CACHE_DIR") or os.path.join(
            os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
            "llm-brain",
        )
        base_real = os.path.realpath(base)
        # Never cache inside the vault itself (derived data stays off the NAS).
        if base_real == self.root or base_real.startswith(self.root + os.sep):
            self.enabled = False
            return
        key = hashlib.sha256(self.root.encode("utf-8", "surrogateescape")).hexdigest()[:24]
        self.path = Path(base) / "records" / f"{key}.v{RECORD_CACHE_FORMAT}.pickle"
        self.fingerprint = _code_fingerprint()
        try:
            with open(self.path, "rb") as stream:
                payload = _CacheUnpickler.load(stream)
            if (
                isinstance(payload, dict)
                and payload.get("format") == RECORD_CACHE_FORMAT
                and payload.get("root") == self.root
                and isinstance(payload.get("entries"), dict)
            ):
                if payload.get("code") == self.fingerprint:
                    self.entries = payload["entries"]
                    if self.trust_seconds > 0:
                        self.token = _change_token(self.root, self._entry_dirs())
                        swept = payload.get("swept")
                        if (
                            isinstance(swept, (int, float))
                            and payload.get("token") == self.token
                            and 0 <= time.time() - swept < self.trust_seconds
                        ):
                            self.trusted, self.swept = True, float(swept)
                else:
                    # New code (an upgrade): keep only what is a pure function
                    # of the bytes (raw, sha, stat key, write time) and drop
                    # parsed/derived fields, so the first run after an upgrade
                    # does not re-read every record over the network.
                    keep = ("raw", "sha", "k", "t")
                    self.entries = {
                        rel: {name: entry[name] for name in keep if name in entry}
                        for rel, entry in payload["entries"].items()
                        if isinstance(entry, dict) and "raw" in entry and "sha" in entry and "k" in entry
                    }
                    self.dirty = bool(self.entries)
        except Exception:  # noqa: BLE001 - a broken cache is just a cold cache
            self.entries = {}
        if self.trust_seconds > 0 and not self.trusted:
            # This run does the full stat sweep; record it so the next
            # read-only run inside the window can trust the cache.
            self.token = self.token if self.token is not None else _change_token(self.root, self._entry_dirs())
            self.swept = time.time()
            self.dirty = True

    def _entry_dirs(self) -> list[str]:
        """Folders outside okf/ that hold cached records (e.g. review/ for --include-proposed)."""
        dirs = {os.path.dirname(rel) for rel in self.entries}
        return [os.path.join(self.root, d) for d in dirs if d and d != "okf" and not d.startswith("okf/")]

    @staticmethod
    def stat_key(st: os.stat_result) -> tuple[int, int, int, int, int]:
        return (st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, st.st_dev)

    def get(self, rel: str, st: os.stat_result) -> dict[str, Any] | None:
        if not self.enabled:
            return None
        entry = self.entries.get(rel)
        if (
            entry is not None
            and entry.get("k") == self.stat_key(st)
            and entry.get("t", 0) - st.st_mtime_ns >= RECORD_CACHE_RACY_NS
        ):
            self.hits += 1
            return entry
        self.misses += 1
        return None

    def put(self, rel: str, st: os.stat_result, entry: dict[str, Any]) -> dict[str, Any]:
        entry["k"] = self.stat_key(st)
        entry["t"] = time.time_ns()
        if self.enabled:
            self.entries[rel] = entry
            self.dirty = True
        return entry

    def prune(self, live: Iterable[str]) -> None:
        keep = set(live)
        for rel in [rel for rel in self.entries if rel not in keep]:
            del self.entries[rel]
            self.dirty = True

    def save(self) -> None:
        if not (self.enabled and self.dirty and self.path is not None):
            return
        import pickle
        import tempfile

        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".rc.", dir=os.fspath(self.path.parent))
            try:
                with os.fdopen(fd, "wb") as stream:
                    pickle.dump(
                        {"format": RECORD_CACHE_FORMAT, "code": self.fingerprint, "root": self.root, "entries": self.entries,
                         "token": self.token, "swept": self.swept},
                        stream,
                        protocol=4,
                    )
                os.replace(temporary, self.path)
            except BaseException:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
                raise
        except Exception:  # noqa: BLE001 - caching must never fail a command
            pass
        self.dirty = False

    def _read_fd(self, path: str, rel: str) -> dict[str, Any]:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise OkfError("not a regular file")
            entry = self.get(rel, st)
            if entry is None:
                chunks = []
                while True:
                    chunk = os.read(fd, 1 << 20)
                    if not chunk:
                        break
                    chunks.append(chunk)
                raw = b"".join(chunks)
                after = os.fstat(fd)
                entry = {"raw": raw, "sha": hashlib.sha256(raw).hexdigest()}
                # Only cache when the file did not change while we read it.
                if self.stat_key(after) == self.stat_key(st):
                    self.put(rel, st, entry)
                else:
                    entry["k"] = None
        finally:
            os.close(fd)
        return entry

    def read(self, path: str, rel: str, need_meta: bool = True) -> dict[str, Any]:
        """Entry for PATH with raw, sha and (optionally) parsed metadata.

        Reads the file only on a miss.  ``meta``/``body_at`` are present when
        the YAML frontmatter parsed; otherwise ``err`` holds the OkfError text.
        """
        # Hit path: one lstat and no open.  On SMB an open+fstat+close is
        # three round trips (about 20 ms per record measured on a NAS); a
        # symlink or non-regular file falls through to the O_NOFOLLOW open
        # below, which fails exactly as before.
        if self.trusted:
            hit = self.entries.get(rel)
            if hit is not None and hit.get("k") and (not need_meta or "meta" in hit or "err" in hit):
                self.hits += 1
                return hit
        entry = None
        bulk = self._bulk_stat(path) if self.bulk and self.enabled else None
        if bulk is not None:
            hit = self.get(rel, bulk)
            if hit is not None and (not need_meta or "meta" in hit or "err" in hit):
                return hit
            # A miss reads through the O_NOFOLLOW open below, which re-checks
            # the file with fstat; a hit with no parse reuses the cached bytes.
            entry = hit
            lst = None
        else:
            try:
                lst = os.lstat(path)
            except OSError:
                lst = None
        if lst is not None and stat.S_ISREG(lst.st_mode):
            hit = self.get(rel, lst)
            if hit is not None and (not need_meta or "meta" in hit or "err" in hit):
                return hit
            entry = hit  # cached bytes are current; only the parse is missing
        if entry is None:
            entry = self._read_fd(path, rel)
        if need_meta and "meta" not in entry and "err" not in entry:
            try:
                text = entry["raw"].decode("utf-8")
            except UnicodeDecodeError:
                entry["err"] = "not valid UTF-8"
            else:
                try:
                    metadata, body = split_frontmatter_text(text)
                    entry["meta"] = metadata
                    entry["body_at"] = len(text) - len(body)
                except OkfError as exc:
                    entry["err"] = str(exc)
            self.dirty = self.dirty or self.enabled
        return entry

    def _bulk_stat(self, path: str) -> _BulkStat | None:
        folder, name = os.path.split(path)
        if folder not in self._bulk_maps:
            seen = self._bulk_reads.get(folder, 0) + 1
            self._bulk_reads[folder] = seen
            if seen < BULK_STAT_MIN_READS:
                return None
            self._bulk_maps[folder] = _bulk_scan(folder)
        found = self._bulk_maps[folder]
        return None if found is None else found.get(name)

    @staticmethod
    def metadata_body(entry: dict[str, Any]) -> tuple[dict[str, Any], str]:
        if "err" in entry:
            raise OkfError(entry["err"])
        text = entry["raw"].decode("utf-8")
        return copy.deepcopy(entry["meta"]), text[entry["body_at"]:]


_RESOLVED: dict[str, Path] = {}


def resolve_path(path: Path) -> Path:
    """Path.resolve() memoised for one process.  The resolver resolves the
    same record paths many times per command (about 25 times per record in a
    brief); each resolve is one lstat per path component, which is a network
    round trip on SMB/NFS.  Failures are not cached and raise as before."""
    key = os.fspath(path)
    found = _RESOLVED.get(key)
    if found is None:
        found = Path(path).resolve()
        _RESOLVED[key] = found
    return found


class LifecycleResolver:
    """Small, read-only resolver shared by capsule and retrieval metadata.

    The CLI remains responsible for locks and writes.  This helper owns the
    YAML-aware parts of relation traversal so commas, aliases and restricted
    metadata cannot be confused with delimiters in shell strings.
    """

    relation_fields = (
        ("brain_supports", "supports", "supported_by"),
        ("brain_conflicts", "conflicts", "conflicted_by"),
        ("brain_supersedes", "supersedes", "superseded_by"),
        ("brain_version_of", "version_of", "versioned_by"),
        ("brain_depends_on", "depends_on", "depended_on_by"),
        ("brain_derived_from", "derived_from", "derived_by"),
    )

    def __init__(self, root: Path, principal: str = "", as_of: str = "") -> None:
        self.root = root.expanduser().resolve()
        self.principal = principal.strip() if isinstance(principal, str) else ""
        self.as_of_error = ""
        if as_of:
            try:
                parsed = dt.datetime.fromisoformat(as_of.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("timezone required")
                self.as_of = parsed
            except (TypeError, ValueError):
                self.as_of = dt.datetime.now(dt.timezone.utc)
                self.as_of_error = "invalid-as-of"
        else:
            self.as_of = dt.datetime.now(dt.timezone.utc)
        self.metadata: dict[Path, dict[str, Any]] = {}
        self.bodies: dict[Path, str] = {}
        self.errors: dict[Path, str] = {}
        self.ref_cache: dict[str, Path | None] = {}
        self.ref_errors: dict[str, str] = {}
        self.relation_errors: set[tuple[Path, str, str]] = set()
        files: list[Path] = []
        okf = self.root / "okf"
        if okf.is_dir():
            for candidate in okf.rglob("*.md"):
                if candidate.name in RESERVED or "retractions" in candidate.parts:
                    continue
                try:
                    resolved = resolve_path(candidate)
                    resolved.relative_to(self.root)
                except (OSError, ValueError):
                    continue
                if resolved.is_file():
                    files.append(resolved)
        self.files = sorted(set(files))
        self.file_set = set(self.files)
        self.cache = RecordCache(self.root)
        # Parse once per request so reverse expansion and state resolution see
        # one stable view and malformed records fail closed consistently.
        for path in self.files:
            self.load(path)
        if self.cache.enabled:
            live = []
            for path in self.files:
                try:
                    live.append(path.relative_to(self.root).as_posix())
                except ValueError:
                    pass
            self.cache.prune(live)
            self.cache.save()

    def load(self, path: Path) -> dict[str, Any]:
        try:
            path = resolve_path(path)
        except OSError:
            return {}
        if path not in self.metadata:
            try:
                cache = getattr(self, "cache", None)
                if cache is not None and cache.enabled:
                    try:
                        rel = path.relative_to(self.root).as_posix()
                    except ValueError:
                        rel = ""
                if cache is not None and cache.enabled and rel:
                    entry = cache.read(os.fspath(path), rel)
                    self.__dict__.setdefault("_raw", {})[path] = entry["raw"]
                    metadata, body = RecordCache.metadata_body(entry)
                else:
                    metadata, body = split_frontmatter(path)
            except (OSError, OkfError):
                metadata, body = {}, ""
                self.errors[path] = "malformed-record"
            self.metadata[path] = metadata
            self.bodies[path] = body
        return self.metadata[path]

    @staticmethod
    def _split_refs(value: Any) -> list[str]:
        if value is None:
            return []
        values = value if isinstance(value, list) else [value]
        result: list[str] = []
        for item in values:
            if not isinstance(item, str):
                raise ValueError("reference must be a string")
            comma_parts = item.split(",")
            for comma_part in comma_parts:
                lines = comma_part.splitlines() or [comma_part]
                found = False
                for line in lines:
                    text = line.strip()
                    if text:
                        result.append(text)
                        found = True
                if not found and len(comma_parts) > 1:
                    raise ValueError("empty reference")
        return list(dict.fromkeys(result))

    @staticmethod
    def refs(value: Any) -> list[str]:
        """Compatibility accessor used by older callers; invalid refs fail closed."""

        try:
            return LifecycleResolver._split_refs(value)
        except ValueError:
            return []

    @staticmethod
    def _safe_ref(ref: Any) -> tuple[str, str | None]:
        if not isinstance(ref, str):
            return "", "invalid-reference"
        text = ref.strip()
        if not text:
            return "", "empty-reference"
        if "\x00" in text or "\n" in text or "\r" in text or "\\" in text:
            return "", "invalid-reference"
        if text.startswith("/"):
            return "", "path-escape"
        if ".." in PurePosixPath(text).parts:
            return "", "path-escape"
        while text.startswith("./"):
            text = text[2:]
        return text, None

    def _parse_relation_refs(self, path: Path, field: str) -> list[str]:
        raw = self.load(path).get(field)
        if raw is not None:
            values = raw if isinstance(raw, list) else [raw]
            if not values or any(
                not isinstance(item, str) or not item.strip() for item in values
            ):
                self.relation_errors.add((path, field, "malformed-relation"))
                raise OkfError("malformed relation")
        try:
            return self._split_refs(raw)
        except ValueError as exc:
            self.relation_errors.add((path, field, "malformed-relation"))
            raise OkfError("malformed relation") from exc

    def _identity_refs(self, path: Path, field: str) -> list[str] | None:
        try:
            return self._split_refs(self.load(path).get(field))
        except ValueError:
            self.relation_errors.add((path, field, "malformed-visibility"))
            return None

    def relative(self, path: Path) -> str:
        return resolve_path(path).relative_to(self.root).as_posix()

    def _secret_bearing(self, path: Path) -> bool:
        cache = self.__dict__.setdefault("_secret_cache", {})
        if path not in cache:
            try:
                # Same bytes the resolver parsed (stat-validated cache entry);
                # otherwise read the file as before.
                raw = self.__dict__.get("_raw", {}).get(resolve_path(path))
                if raw is None:
                    raw = path.read_bytes()
                cache[path] = bool(SECRET_BEARING.search(raw))
            except OSError:
                cache[path] = True
        return cache[path]

    def _record_sensitivity(self, path: Path) -> str:
        metadata = self.load(path)
        value = metadata.get("brain_sensitivity", metadata.get("sensitivity", "internal"))
        if value is None:
            return "internal"
        return value if isinstance(value, str) else "invalid"

    def visible(self, path: Path, *, strict_principal: bool = True) -> bool:
        try:
            path = resolve_path(path)
        except OSError:
            return False
        if path not in self.file_set or path in self.errors:
            return False
        # Only the explicitly approved internal class is traversable.  Unknown
        # or malformed classifications fail closed instead of being emitted.
        if self._record_sensitivity(path) != "internal":
            return False
        scoped = self._identity_refs(path, "brain_principal")
        audience = self._identity_refs(path, "brain_audience")
        if scoped is None or audience is None:
            return False
        identities = scoped + audience
        if self._secret_bearing(path):
            # 0.11: secret-bearing records stay as written but are owner-only:
            # treated as scoped to LLM_BRAIN_OWNER_PRINCIPAL (or to nobody).
            owner = os.environ.get("LLM_BRAIN_OWNER_PRINCIPAL", "")
            identities = [owner] if owner else ["\x00owner-only"]
        if not identities:
            return True
        if not self.principal:
            # LLM_BRAIN_STRICT_PRINCIPAL=1: callers without a principal see
            # only unscoped records (per-person brains on shared hosts).
            return not strict_principal and os.environ.get("LLM_BRAIN_STRICT_PRINCIPAL", "0") != "1"
        return self.principal in identities

    def effective(self, path: Path) -> bool:
        try:
            path = resolve_path(path)
        except OSError:
            return False
        if path not in self.file_set or path in self.errors:
            return False
        metadata = self.load(path)
        if (self.root / "okf" / "retractions" / f"{path.stem}.md").is_file():
            return False
        status_value = metadata.get("status", "stable")
        review_value = metadata.get("brain_review_state", metadata.get("review_state", ""))
        if not isinstance(status_value, str) or not isinstance(review_value, str):
            return False
        status = status_value.strip().lower()
        review_state = review_value.strip().lower()
        if status == "deprecated":
            return False
        if review_state:
            return review_state == "approved"
        return status == "stable"

    def canonical_ref(self, ref: str) -> Path | None:
        text, error = self._safe_ref(ref)
        if error:
            if isinstance(ref, str):
                self.ref_errors[ref.strip()] = error
            return None
        if text in self.ref_cache:
            return self.ref_cache[text]
        try:
            candidate_path = resolve_path(self.root / text)
            candidate_path.relative_to(self.root)
        except (OSError, ValueError):
            candidate_path = None
        if candidate_path is not None and candidate_path in self.file_set:
            self.ref_cache[text] = candidate_path
            return candidate_path
        wanted = text.removesuffix(".md")
        matches: list[Path] = []
        for path in self.files:
            rel = self.relative(path)
            ids = []
            metadata = self.load(path)
            for key in (
                "brain_claim_id",
                "brain_procedure_id",
                "brain_reference_id",
                "brain_topic_id",
            ):
                identity_refs = self._identity_refs(path, key)
                if identity_refs is not None:
                    ids.extend(identity_refs)
            if text in (rel, f"{rel}.md", path.stem) or wanted == path.stem or text in ids:
                matches.append(path)
        result = matches[0] if len(matches) == 1 else None
        self.ref_cache[text] = result
        if result is None:
            self.ref_errors[text] = "ambiguous-reference" if len(matches) > 1 else "missing-reference"
        return result

    def _targets(self, path: Path, field: str) -> list[Path]:
        targets: list[Path] = []
        for reference in self._parse_relation_refs(path, field):
            target = self.canonical_ref(reference)
            if target is None:
                raise OkfError("unresolved relation target")
            if target not in targets:
                targets.append(target)
        return sorted(targets, key=self.relative)

    def _temporal_detail(self, path: Path) -> tuple[str, str]:
        metadata = self.load(path)
        start_value = metadata.get("brain_valid_from")
        end_value = metadata.get("brain_valid_to")
        if not isinstance(start_value, str) or not isinstance(end_value, str):
            return "unknown-validity", "validity-not-declared"
        try:
            start = dt.datetime.fromisoformat(start_value.strip().replace("Z", "+00:00"))
            end = dt.datetime.fromisoformat(end_value.strip().replace("Z", "+00:00"))
            if start.tzinfo is None or end.tzinfo is None:
                raise ValueError("timezone required")
        except ValueError:
            return "unknown-validity", "invalid-validity"
        if start >= end:
            return "unknown-validity", "invalid-validity"
        if start <= self.as_of < end:
            return "current", "within-validity"
        return "historical", "outside-validity"

    def temporal(self, path: Path) -> str:
        return self._temporal_detail(path)[0]

    def _current_successors(self, path: Path) -> tuple[list[Path], str | None]:
        successors: list[Path] = []
        for candidate in self.files:
            if candidate == path or not self.effective(candidate) or not self.visible(candidate):
                continue
            try:
                relation_targets = self._targets(candidate, "brain_supersedes")
                relation_targets += self._targets(candidate, "brain_version_of")
            except OkfError:
                continue
            if path not in relation_targets:
                continue
            candidate_temporal, _ = self._temporal_detail(candidate)
            if candidate_temporal == "current":
                successors.append(candidate)
        successors = sorted(set(successors), key=self.relative)
        return successors, None

    def resolve(
        self, path: Path, stack: tuple[str, ...] = (), depth: int = 0
    ) -> dict[str, Any]:
        try:
            path = resolve_path(path)
        except OSError:
            return {"state": "unresolved-dependency", "reason": "missing", "effective_ref": ""}
        rel = self.relative(path) if path in self.file_set else ""
        if depth >= 32:
            return {"state": "invalid-cycle", "reason": "lineage-hop-limit", "effective_ref": rel}
        if rel in stack:
            return {"state": "invalid-cycle", "reason": "dependency-cycle", "effective_ref": rel}
        if path not in self.file_set:
            return {"state": "unresolved-dependency", "reason": "missing", "effective_ref": rel}
        if path in self.errors:
            return {
                "state": "unresolved-dependency",
                "reason": "malformed-record",
                "effective_ref": rel,
            }
        if not self.visible(path):
            return {
                "state": "unresolved-inaccessible",
                "reason": "not-visible",
                "effective_ref": rel,
            }
        if not self.effective(path):
            return {"state": "historical", "reason": "not-effective", "effective_ref": rel}
        temporal, temporal_reason = self._temporal_detail(path)
        if temporal == "historical":
            return {"state": "historical", "reason": temporal_reason, "effective_ref": rel}
        metadata = self.load(path)
        next_stack = stack + (rel,)

        # A conflict is active only when its target is also current.  Future or
        # expired conflict records must not poison an as-of resolution.
        try:
            conflict_targets = self._targets(path, "brain_conflicts")
        except OkfError:
            return {"state": "unresolved-conflict", "reason": "malformed-conflict", "effective_ref": rel}
        for target in conflict_targets:
            if not self.visible(target):
                return {
                    "state": "unresolved-inaccessible",
                    "reason": "conflict-not-visible",
                    "effective_ref": rel,
                }
            if not self.effective(target):
                continue
            target_temporal, _ = self._temporal_detail(target)
            if target_temporal == "current":
                return {
                    "state": "unresolved-conflict",
                    "reason": "explicit-conflict",
                    "effective_ref": rel,
                }
            if target_temporal == "unknown-validity":
                return {
                    "state": "unresolved-conflict",
                    "reason": "unknown-validity-conflict",
                    "effective_ref": rel,
                }

        # Lineage declarations are required to resolve to an accessible record,
        # but the predecessor may naturally be historical after a replacement.
        for field in ("brain_supersedes", "brain_version_of"):
            try:
                lineage_targets = self._targets(path, field)
            except OkfError:
                return {
                    "state": "unresolved-dependency",
                    "reason": "malformed-lineage",
                    "effective_ref": rel,
                }
            for target in lineage_targets:
                if not self.visible(target):
                    return {
                        "state": "unresolved-inaccessible",
                        "reason": "lineage-not-visible",
                        "effective_ref": rel,
                    }
                if not self.effective(target):
                    return {
                        "state": "unresolved-dependency",
                        "reason": "lineage-not-effective",
                        "effective_ref": rel,
                    }

        successors, _ = self._current_successors(path)
        if len(successors) > 1:
            return {
                "state": "unresolved-conflict",
                "reason": "ambiguous-successor",
                "effective_ref": rel,
            }
        if successors:
            successor = self.resolve(successors[0], next_stack, depth + 1)
            if successor["state"] == "invalid-cycle":
                return {
                    "state": "invalid-cycle",
                    "reason": (
                        successor.get("reason", "successor-cycle")
                        if successor.get("reason") == "lineage-hop-limit"
                        else "successor-cycle"
                    ),
                    "effective_ref": rel,
                }
            if successor["state"] in {
                "unresolved-conflict",
                "unresolved-dependency",
                "unresolved-inaccessible",
            }:
                return {
                    "state": successor["state"],
                    "reason": f"successor-{successor['reason']}",
                    "effective_ref": rel,
                }
            return {
                "state": "historical",
                "reason": "superseded",
                "effective_ref": successor.get("effective_ref", self.relative(successors[0])),
            }

        state_key_value = metadata.get("brain_state_key", "")
        if state_key_value is not None and not isinstance(state_key_value, str):
            return {
                "state": "unresolved-conflict",
                "reason": "invalid-state-key",
                "effective_ref": rel,
            }
        state_key = state_key_value.strip() if isinstance(state_key_value, str) else ""
        if state_key:
            for other in self.files:
                if other == path or not self.visible(other) or not self.effective(other):
                    continue
                other_metadata = self.load(other)
                other_key = other_metadata.get("brain_state_key", "")
                if not isinstance(other_key, str) or other_key.strip() != state_key:
                    continue
                other_temporal, _ = self._temporal_detail(other)
                if other_temporal == "unknown-validity":
                    return {
                        "state": "unresolved-conflict",
                        "reason": "unknown-validity-state-record",
                        "effective_ref": rel,
                    }
                if other_temporal != "current":
                    continue
                other_successors, _ = self._current_successors(other)
                if len(other_successors) > 1:
                    return {
                        "state": "unresolved-conflict",
                        "reason": "ambiguous-successor",
                        "effective_ref": rel,
                    }
                if not other_successors:
                    return {
                        "state": "unresolved-conflict",
                        "reason": "multiple-active-state-records",
                        "effective_ref": rel,
                    }

        try:
            dependencies = self._targets(path, "brain_depends_on")
        except OkfError:
            return {
                "state": "unresolved-dependency",
                "reason": "malformed-dependency",
                "effective_ref": rel,
            }
        for target in dependencies:
            if not self.visible(target):
                return {
                    "state": "unresolved-inaccessible",
                    "reason": "dependency-not-visible",
                    "effective_ref": rel,
                }
            if not self.effective(target):
                return {
                    "state": "unresolved-dependency",
                    "reason": "dependency-not-effective",
                    "effective_ref": rel,
                }
            dependency = self.resolve(target, next_stack, depth + 1)
            if dependency["state"] != "current":
                if dependency["state"] == "invalid-cycle":
                    return {
                        "state": "invalid-cycle",
                        "reason": f"dependency-{dependency['reason']}",
                        "effective_ref": rel,
                    }
                return {
                    "state": "unresolved-dependency",
                    "reason": f"dependency-{dependency['state']}",
                    "effective_ref": rel,
                }
        if temporal == "unknown-validity":
            return {"state": temporal, "reason": temporal_reason, "effective_ref": rel}
        return {"state": "current", "reason": "effective", "effective_ref": rel}

    def dependency_snapshot(self, references: list[str]) -> dict[str, Any]:
        if self.as_of_error:
            return self._snapshot_failure("unresolved-dependency", self.as_of_error)
        try:
            references = self._split_refs(references)
        except ValueError:
            return self._snapshot_failure("unresolved-dependency", "malformed-reference")
        roots: list[Path] = []
        seen_roots: set[Path] = set()
        for reference in references:
            target = self.canonical_ref(reference)
            if target is None:
                return self._snapshot_failure(
                    "unresolved-inaccessible"
                    if self.ref_errors.get(reference) == "path-escape"
                    else "unresolved-dependency",
                    self.ref_errors.get(reference, "dependency-missing"),
                )
            if target not in seen_roots:
                roots.append(target)
                seen_roots.add(target)
        if not roots:
            refs_wire = "none"
            hashes_wire = "none"
            return {
                "state": "none",
                "reason": "no-dependencies",
                "refs": [],
                "hashes": [],
                "refs_wire": refs_wire,
                "hashes_wire": hashes_wire,
                "snapshot_hash": hashlib.sha256(
                    f"{refs_wire}|{hashes_wire}".encode()
                ).hexdigest(),
                "node_count": 0,
            }
        records: dict[str, dict[str, str]] = {}
        visited: set[Path] = set()

        def walk(path: Path, stack: tuple[str, ...], depth: int) -> dict[str, Any] | None:
            if depth >= 32:
                return self._snapshot_failure("invalid-cycle", "dependency-lineage-hop-limit")
            if len(visited) >= 128 and path not in visited:
                return self._snapshot_failure("unresolved-dependency", "dependency-node-limit")
            if path not in self.file_set:
                return self._snapshot_failure("unresolved-dependency", "dependency-missing")
            rel = self.relative(path)
            if rel in stack:
                return self._snapshot_failure("invalid-cycle", "dependency-cycle")
            if path in visited:
                return None
            resolution = self.resolve(path, stack, depth)
            if resolution["state"] != "current":
                return self._snapshot_failure(
                    resolution["state"], f"dependency-{resolution['reason']}"
                )
            visited.add(path)
            metadata = self.load(path)
            state_key_value = metadata.get("brain_state_key", "")
            if state_key_value is not None and not isinstance(state_key_value, str):
                return self._snapshot_failure("unresolved-conflict", "invalid-state-key")
            record = {
                "ref": rel,
                "hash": hashlib.sha256(path.read_bytes()).hexdigest(),
                "state": resolution["state"],
                "effective_ref": resolution.get("effective_ref", rel),
                "state_key": "",
            }
            state_key = state_key_value.strip() if isinstance(state_key_value, str) else ""
            record["state_key"] = state_key
            records[rel] = record
            next_stack = stack + (rel,)
            try:
                dependencies = self._targets(path, "brain_depends_on")
            except OkfError:
                return self._snapshot_failure("unresolved-dependency", "malformed-dependency")
            for target in dependencies:
                failure = walk(target, next_stack, depth + 1)
                if failure is not None:
                    return failure
            # A current path cannot have a current successor (resolve would have
            # marked it historical), but checking this reverse edge keeps the
            # closure complete if a future resolver policy returns an effective
            # successor instead of rejecting the stale reference.
            successors, _ = self._current_successors(path)
            for target in successors:
                failure = walk(target, next_stack, depth + 1)
                if failure is not None:
                    return failure
            return None

        for root in roots:
            failure = walk(root, (), 0)
            if failure is not None:
                return failure
        ordered = [records[key] for key in sorted(records)]
        refs = [record["ref"] for record in ordered]
        wire: list[str] = []
        for record in ordered:
            value = (
                f"{record['ref']}={record['hash']}|state={record['state']}"
                f"|effective={record['effective_ref']}|state_key={record['state_key']}"
            )
            wire.append(value)
        refs_wire = ",".join(refs) or "none"
        hashes_wire = ";".join(wire) or "none"
        return {
            "state": "current",
            "reason": "effective",
            "refs": refs,
            "hashes": ordered,
            "refs_wire": refs_wire,
            "hashes_wire": hashes_wire,
            "snapshot_hash": hashlib.sha256(
                f"{refs_wire}|{hashes_wire}".encode()
            ).hexdigest(),
            "node_count": len(ordered),
        }

    @staticmethod
    def _snapshot_failure(state: str, reason: str) -> dict[str, Any]:
        hidden = state in {"unresolved-inaccessible"}
        return {
            "state": state,
            "reason": reason,
            "refs": [] if hidden else [],
            "hashes": [],
            "refs_wire": "none",
            "hashes_wire": "none",
            "snapshot_hash": "none",
            "node_count": 0,
        }

    def lifecycle_bundle(
        self,
        root_file: Path,
        *,
        root_files: list[Path] | None = None,
        max_records: int = 20,
    ) -> dict[str, Any]:
        try:
            record_limit = max(0, min(int(max_records), 20))
        except (TypeError, ValueError):
            record_limit = 20
        requested_roots = [root_file]
        if root_files:
            requested_roots.extend(root_files)
        roots: list[Path] = []
        for candidate in requested_roots:
            try:
                resolved = resolve_path(candidate)
            except OSError:
                continue
            # Root selection is itself visibility-filtered so restricted or
            # principal-scoped roots cannot consume a visible root slot or
            # alter an emitted count.
            if (
                resolved in self.file_set
                and resolved not in roots
                and self.visible(resolved)
            ):
                roots.append(resolved)
        root_limit_hit = len(roots) > 20
        if root_limit_hit:
            roots = roots[:20]
        bounds = {
            "max_depth": 8,
            "max_records": record_limit,
            "max_visited": 128,
            "max_roots": 20,
        }
        result: dict[str, Any] = {
            "schema": "llm-brain.lifecycle-bundle.v1",
            "records": [],
            "warnings": [],
            "incomplete": False,
            "visited_count": 0,
            "max_depth": 8,
            "max_records": record_limit,
            "max_visited": 128,
            "bounds": bounds,
            "resolution": "complete",
        }
        if roots:
            result["root_refs"] = [self.relative(root) for root in roots]
        if self.as_of_error:
            result["warnings"] = [self.as_of_error]
            result["incomplete"] = True
            result["resolution"] = "incomplete"
            return result
        if not roots:
            result["resolution"] = "hidden"
            return result

        warnings: set[str] = set()
        if root_limit_hit:
            warnings.add("root-bound")
            result["incomplete"] = True
        visited_global: set[Path] = set()
        record_map: dict[str, dict[str, Any]] = {}
        budget = {"records": 0}
        reverse: dict[Path, list[tuple[str, Path]]] = {}
        hidden_reverse: set[Path] = set()
        active_bundle_keys: set[str] | None = None

        def warn(code: str, *, incomplete: bool = True) -> None:
            warnings.add(code)
            if incomplete:
                result["incomplete"] = True

        # All frontmatter was parsed in __init__.  Building this once per
        # request avoids a per-root reparse and makes the multi-root budget
        # deterministic.
        for candidate in self.files:
            candidate_visible = self.visible(candidate)
            for field, _forward_name, reverse_name in self.relation_fields:
                try:
                    targets = self._targets(candidate, field)
                except OkfError:
                    # The malformed candidate is not itself reachable yet;
                    # report the relationship only if the selected traversal
                    # reaches that candidate through another edge.
                    continue
                for target in targets:
                    if candidate_visible and self.visible(target):
                        reverse.setdefault(target, []).append((reverse_name, candidate))
                    elif self.visible(target):
                        hidden_reverse.add(target)
        for target in reverse:
            reverse[target] = sorted(
                set(reverse[target]), key=lambda item: (item[0], self.relative(item[1]))
            )

        def add_record(path: Path, roles: set[str], relation_names: set[str]) -> None:
            rel = self.relative(path)
            if active_bundle_keys is not None:
                active_bundle_keys.add(rel)
            if rel in record_map:
                record_map[rel]["roles"] = sorted(
                    set(record_map[rel].get("roles", [])) | roles
                )
                record_map[rel]["relations"] = sorted(
                    set(record_map[rel].get("relations", [])) | relation_names
                )
                record_map[rel]["role"] = record_map[rel]["roles"][0]
                record_map[rel]["relation"] = record_map[rel]["relations"][0]
                return
            if budget["records"] >= record_limit:
                warn("record-bound")
                return
            try:
                content_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            except OSError:
                warn("unresolved-record")
                return
            metadata = self.load(path)
            title_value = metadata.get("title", "")
            title = title_value.strip() if isinstance(title_value, str) else ""
            excerpt = re.sub(r"\s+", " ", self.bodies.get(path, "")).strip()[:320]
            state = self.resolve(path)
            if state.get("state") == "unknown-validity":
                warn("unknown-validity", incomplete=False)
            ordered_roles = sorted(roles)
            ordered_relations = sorted(relation_names)
            record_map[rel] = {
                "role": ordered_roles[0],
                "relation": ordered_relations[0],
                "roles": ordered_roles,
                "relations": ordered_relations,
                "ref": rel,
                "effective_ref": state.get("effective_ref", rel),
                "state": state.get("state", "unknown-validity"),
                "state_reason": state.get("reason", "unknown"),
                "hash": content_hash,
                "title": title,
                "excerpt": excerpt,
            }
            budget["records"] += 1

        def walk(
            path: Path,
            depth: int,
            roles: set[str],
            relation_names: set[str],
            stack: tuple[Path, ...],
            is_root: bool = False,
        ) -> None:
            try:
                path = resolve_path(path)
            except OSError:
                warn("unresolved-relation")
                return
            if depth > 8:
                warn("depth-bound")
                return
            if path not in self.file_set or path in self.errors:
                warn("unresolved-relation")
                return
            if not self.visible(path):
                warn("hidden-relation")
                return
            already_visited = path in visited_global
            if already_visited:
                if not is_root:
                    add_record(path, roles, relation_names)
                return
            if path in stack:
                warn("cycle")
                return
            if not already_visited:
                if len(visited_global) >= 128:
                    warn("visited-bound")
                    return
                visited_global.add(path)
                result["visited_count"] = len(visited_global)
            metadata = self.load(path)
            if not is_root:
                add_record(path, roles, relation_names)
                if budget["records"] >= record_limit:
                    # The record itself is allowed; only further expansion is
                    # truncated and reported as incomplete.
                    if any(
                        metadata.get(field) not in (None, "", [])
                        for field, _forward_name, _reverse_name in self.relation_fields
                    ):
                        warn("record-bound")
                    return
            next_stack = stack + (path,)
            for field, forward_name, _reverse_name in self.relation_fields:
                try:
                    targets = self._targets(path, field)
                except OkfError:
                    warn("unresolved-relation")
                    continue
                for target in targets:
                    if not self.visible(target):
                        warn("hidden-relation")
                        continue
                    if depth >= 8:
                        warn("depth-bound")
                        continue
                    walk(
                        target,
                        depth + 1,
                        {forward_name},
                        {forward_name},
                        next_stack,
                    )
            for reverse_name, candidate in reverse.get(path, []):
                if depth >= 8:
                    warn("depth-bound")
                    continue
                walk(
                    candidate,
                    depth + 1,
                    {reverse_name},
                    {reverse_name},
                    next_stack,
                )
            if path in hidden_reverse:
                warn("hidden-relation")

        bundles: list[dict[str, Any]] = []
        for root in roots:
            before_visited = set(visited_global)
            active_bundle_keys = set()
            if not self.visible(root):
                continue
            walk(root, 0, set(), set(), (), is_root=True)
            bundle_records = [record_map[key] for key in sorted(active_bundle_keys)]
            bundle = {
                "schema": "llm-brain.lifecycle-bundle.v1",
                "root_ref": self.relative(root),
                "records": bundle_records,
                "warnings": sorted(warnings),
                "incomplete": bool(result["incomplete"]),
                "visited_count": len(visited_global - before_visited),
                "max_depth": 8,
                "max_records": record_limit,
                "max_visited": 128,
                "bounds": bounds,
                "resolution": "incomplete" if result["incomplete"] else "complete",
            }
            bundles.append(bundle)

        result["records"] = [record_map[key] for key in sorted(record_map)]
        result["warnings"] = sorted(warnings)
        result["resolution"] = "incomplete" if result["incomplete"] else "complete"
        if len(roots) > 1:
            result["evidence_bundles"] = bundles
        return result


def command_dependency_snapshot(args: argparse.Namespace) -> int:
    resolver = LifecycleResolver(Path(args.root), args.principal or "", args.as_of or "")
    payload = resolver.dependency_snapshot(args.refs or "")
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


def command_lifecycle_bundle(args: argparse.Namespace) -> int:
    resolver = LifecycleResolver(Path(args.root), args.principal or "", args.as_of or "")
    path = resolver.canonical_ref(args.file)
    if path is None:
        raise OkfError("lifecycle file is unavailable")
    try:
        extra_refs = LifecycleResolver._split_refs(args.roots or "")
    except ValueError as exc:
        raise OkfError("lifecycle roots are malformed") from exc
    extra_roots: list[Path] = []
    for reference in extra_refs:
        target = resolver.canonical_ref(reference)
        if target is None:
            raise OkfError("lifecycle root is unavailable")
        if target != path and target not in extra_roots:
            extra_roots.append(target)
    payload = resolver.lifecycle_bundle(
        path, root_files=extra_roots, max_records=args.max_records
    )
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


def command_migrate_concept(args: argparse.Namespace) -> int:
    path = Path(args.file)
    metadata, body = split_frontmatter(path)
    metadata, body = migrate_metadata(
        metadata, body, args.actor, args.at, args.type_hint
    )
    metadata["brain_schema_version"] = 3
    dump_document(path, metadata, body)
    return 0


def command_migrate_bundle(args: argparse.Namespace) -> int:
    migrate_bundle(
        Path(args.bundle), args.project_id, args.title, args.actor, args.at
    )
    return 0


def command_audit(args: argparse.Namespace) -> int:
    counts = audit_counts(Path(args.bundle))
    if args.json:
        print(json.dumps(counts, sort_keys=True, separators=(",", ":")))
    else:
        print(" ".join(f"{key}={value}" for key, value in counts.items()))
    return 0


def command_hash(args: argparse.Namespace) -> int:
    digest = hashlib.sha256()
    root = Path(args.bundle)
    for path in sorted(root.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    print(digest.hexdigest())
    return 0


def command_plugin_info(args: argparse.Namespace) -> int:
    try:
        payload = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise OkfError(f"invalid plugin inventory: {exc}") from exc
    if isinstance(payload, list):
        installed = payload
    elif isinstance(payload, dict):
        installed = next(
            (
                payload[key]
                for key in ("installed", "plugins", "installedPlugins")
                if isinstance(payload.get(key), list)
            ),
            [],
        )
    else:
        installed = []
    for plugin in installed:
        if not isinstance(plugin, dict):
            continue
        identity = scalar_text(plugin.get("name") or plugin.get("id"))
        if identity.split("@", 1)[0] != args.name:
            continue
        source = plugin.get("source")
        source_path = (
            source.get("path", "") if isinstance(source, dict) else ""
        ) or scalar_text(
            plugin.get("installPath")
            or plugin.get("path")
            or plugin.get("cachePath")
        )
        source_type = ""
        if isinstance(source, dict):
            source_type = scalar_text(
                source.get("sourceType") or source.get("source") or source.get("type")
            )
        marketplace_source = plugin.get("marketplaceSource")
        if not source_type and isinstance(marketplace_source, dict):
            source_type = scalar_text(
                marketplace_source.get("sourceType")
                or marketplace_source.get("source")
                or marketplace_source.get("type")
            )
        if not source_type and source_path:
            source_type = "local"
        marketplace = scalar_text(
            plugin.get("marketplaceName") or plugin.get("marketplace")
        )
        if not marketplace and "@" in identity:
            marketplace = identity.split("@", 1)[1]
        print(
            "\t".join(
                (
                    marketplace or "none",
                    scalar_text(plugin.get("version")) or "unknown",
                    scalar_text(source_path) or "none",
                    source_type or "unknown",
                )
            )
        )
        return 0
    return 1


def command_manifest_info(args: argparse.Namespace) -> int:
    try:
        payload = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise OkfError(f"invalid package manifest: {exc}") from exc
    if not isinstance(payload, dict):
        raise OkfError("package manifest must be a JSON object")
    print(
        "\t".join(
            (
                scalar_text(payload.get("name")) or "none",
                scalar_text(payload.get("version")) or "unknown",
                scalar_text(payload.get("type")) or "none",
            )
        )
    )
    return 0


def command_audit_verify(args: argparse.Namespace) -> int:
    """One line per problem, in file order, exactly as verify_audit_v2's shell
    loop reports them: truncated, discontinuity, mismatch.  The header line
    is checked by the caller.  Exit 3 when a byte could make the shell read
    differ (the caller then runs its own loop)."""
    try:
        raw = Path(args.file).read_bytes()
    except OSError as exc:
        raise OkfError(str(exc)) from exc
    lines = raw.split(b"\n")
    lines = lines[1:-1]  # header, and the unterminated tail `read` never sees
    expected_prev = b""
    findings: list[str] = []
    for line in lines:
        if b"\0" in line or b"\x1c" in line:
            return 3
        fields = line.split(b"\t")
        if len(fields) != 11 or line == b"":
            findings.append("truncated")
            continue
        if fields[9] != expected_prev:
            findings.append("discontinuity")
        if hashlib.sha256(b"|".join(fields[:10])).hexdigest().encode("ascii") != fields[10]:
            findings.append("mismatch")
        expected_prev = fields[10]
    for finding in findings:
        print(finding)
    return 0


# --- OKF backfill (0.12): additive `description:` + generated per-folder index.md ---
# Only adds: one front-matter line per record (inserted before the closing
# `---`, body bytes untouched) and index.md files in folders that have none.
# Every write is atomic; the undo manifest stores the exact inserted bytes
# and offsets so `--undo` restores each file byte for byte.
BACKFILL_MARKER = "<!-- memthena:okf-index v1 (generated; `llm-brain index build` refreshes it) -->"
BACKFILL_DIR = "migrations/okf-backfill"
RESTRICTED_TITLE = "Restricted record"
_DESC_MAX = 200
_BF_VERSION = 1


def _bf_records(okf_root: Path) -> list[Path]:
    out = []
    for path in okf_root.rglob("*.md"):
        if path.name in RESERVED or path.is_symlink() or not path.is_file():
            continue
        out.append(path)
    return sorted(out)


def _bf_restricted(meta: dict[str, Any] | None, raw: bytes) -> bool:
    """Secret-bearing, non-internal or principal/audience-scoped: owner-only."""
    if SECRET_BEARING.search(raw):
        return True
    if not isinstance(meta, dict):
        return True
    sensitivity = meta.get("brain_sensitivity", meta.get("sensitivity", "internal"))
    if sensitivity not in (None, "internal"):
        return True
    for field in ("brain_principal", "brain_audience"):
        value = meta.get(field)
        if value not in (None, "", []):
            return True
    return False


def _bf_clean(text: str, limit: int) -> str:
    text = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", text)
    text = re.sub(r"\[\[([^\]]+)\]\]", r"\1", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[`*_~<>\[\]\"\\]", "", text)
    text = "".join(ch if ch.isprintable() else " " for ch in text)
    text = re.sub(r"\s+", " ", text).strip(" -:#")
    if len(text) > limit:
        cut = text[:limit].rsplit(" ", 1)[0].rstrip(" ,;:")
        text = cut + "..."
    return text


def _bf_description(body: str) -> str:
    paragraph: list[str] = []
    fence = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = not fence
            if paragraph:
                break
            continue
        if fence:
            continue
        if not stripped:
            if paragraph:
                break
            continue
        if stripped.startswith(("#", "|", "<!--", "---", ">")) and not paragraph:
            continue
        paragraph.append(re.sub(r"^([-*+]|\d+[.)])\s+", "", stripped))
    text = " ".join(paragraph)
    match = re.match(r"(.{20,}?[.!?])(\s|$)", text)
    if match:
        text = match.group(1)
    text = _bf_clean(text, _DESC_MAX)
    if len(text) < 12 or SECRET_BEARING.search(text.encode("utf-8")):
        return ""
    return text


def _bf_title(meta: dict[str, Any] | None, path: Path, restricted: bool) -> str:
    if restricted:
        return RESTRICTED_TITLE
    title = meta.get("title") if isinstance(meta, dict) else None
    title = _bf_clean(title if isinstance(title, str) and title.strip() else path.stem, 120)
    if not title or SECRET_BEARING.search(title.encode("utf-8")):
        return RESTRICTED_TITLE
    return title


def _bf_insertion(raw: bytes, description: str) -> tuple[int, bytes] | None:
    """Offset and bytes for one `description:` line before the closing ---."""
    if raw.startswith(b"---\r\n"):
        newline = b"\r\n"
    elif raw.startswith(b"---\n"):
        newline = b"\n"
    else:
        return None
    offset = 0
    for index, line in enumerate(raw.splitlines(keepends=True)):
        if index > 0 and line.rstrip(b"\r\n") == b"---":
            if not raw[:offset].endswith(newline):
                return None
            line_bytes = b"description: " + json.dumps(description, ensure_ascii=False).encode("utf-8") + newline
            return offset, line_bytes
        offset += len(line)
    return None


def _bf_atomic_write(path: Path, data: bytes, mode: int | None, expect: os.stat_result | None) -> bool:
    if expect is not None:
        try:
            now = os.lstat(path)
        except OSError:
            return False
        if RecordCache.stat_key(now) != RecordCache.stat_key(expect):
            return False
    temporary = path.with_name(f".{path.name}.okfbf.{os.getpid()}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(mode) if mode is not None else 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return True


def _bf_one(path: Path, rel: str, entry: dict[str, Any]) -> tuple[str, dict[str, Any], dict[str, Any] | None]:
    """(count key, index record, edit plan or None) for one record's bytes."""
    raw = entry["raw"]
    meta = entry.get("meta")
    restricted = _bf_restricted(meta, raw)
    record = {"title": _bf_title(meta, path, restricted), "restricted": restricted, "description": ""}
    if "err" in entry:
        return "unparseable", record, None
    if restricted:
        return "restricted", record, None
    existing = meta.get("description")
    if isinstance(existing, str) and existing.strip():
        clean = _bf_clean(existing, _DESC_MAX)
        record["description"] = "" if SECRET_BEARING.search(clean.encode("utf-8")) else clean
        return "has_description", record, None
    if "description" in meta:
        return "has_description", record, None
    if "/retractions/" in "/" + rel:
        return "retraction", record, None
    body = raw.decode("utf-8")[entry["body_at"]:]
    description = _bf_description(body)
    if not description:
        return "no_lead", record, None
    insertion = _bf_insertion(raw, description)
    if insertion is None:
        return "no_frontmatter_slot", record, None
    offset, line_bytes = insertion
    new_raw = raw[:offset] + line_bytes + raw[offset:]
    try:
        new_meta, new_body = split_frontmatter_text(new_raw.decode("utf-8"))
    except OkfError:
        return "no_frontmatter_slot", record, None
    expected = dict(meta)
    expected["description"] = description
    if new_meta != expected or new_body != body:
        return "no_frontmatter_slot", record, None
    record["description"] = description
    plan = {"offset": offset, "insert": line_bytes.decode("utf-8"), "before_sha": entry["sha"], "after_sha": hashlib.sha256(new_raw).hexdigest(), "description": description}
    return "add", record, plan


def _bf_scan(project: Path, cache: RecordCache) -> dict[str, Any]:
    okf_root = project / "okf"
    plans: list[dict[str, Any]] = []
    counts = {"records": 0, "add": 0, "has_description": 0, "restricted": 0, "no_lead": 0, "unparseable": 0, "retraction": 0, "no_frontmatter_slot": 0}
    info: dict[str, dict[str, Any]] = {}
    for path in _bf_records(okf_root):
        rel = path.relative_to(project).as_posix()
        counts["records"] += 1
        entry = cache.read(os.fspath(path), rel)
        # The derived result rides in the stat-checked cache entry, so a
        # warm check or index-build refresh skips the YAML re-verification.
        derived = entry.get("bf")
        if not (isinstance(derived, tuple) and len(derived) == 4 and derived[0] == _BF_VERSION):
            key, record, plan = _bf_one(path, rel, entry)
            derived = (_BF_VERSION, key, record, plan)
            if entry.get("k") is not None:
                entry["bf"] = derived
                cache.dirty = cache.dirty or cache.enabled
        _, key, record, plan = derived
        # 26 Oct: a retracted record stays listed (lineage) but loses its
        # title and description in generated folder indexes.
        if "/retractions/" not in "/" + rel and (okf_root / "retractions" / path.name).is_file():
            record, plan = {"title": "Retracted record", "restricted": True, "description": ""}, None
        counts[key] += 1
        info[rel] = dict(record, rel=rel)
        if plan is not None:
            plans.append(dict(plan, rel=rel))
    return {"plans": plans, "counts": counts, "info": info}


def _bf_folders(project: Path, info: dict[str, dict[str, Any]]) -> list[str]:
    folders: set[str] = set()
    for rel in info:
        parent = PurePosixPath(rel).parent
        while parent.as_posix() not in ("okf", "."):
            folders.add(parent.as_posix())
            parent = parent.parent
    return sorted(folders)


def _bf_index_text(folder: str, folders: list[str], info: dict[str, dict[str, Any]]) -> str:
    name = PurePosixPath(folder).name
    lines = [BACKFILL_MARKER, f"# {name.replace('-', ' ').replace('_', ' ').title()}", ""]
    subs = [f for f in folders if PurePosixPath(f).parent.as_posix() == folder]
    if subs:
        lines += ["## Folders", ""]
        lines += [f"* [{PurePosixPath(s).name}]({PurePosixPath(s).name}/)" for s in subs]
        lines.append("")
    records = sorted(rel for rel in info if PurePosixPath(rel).parent.as_posix() == folder)
    if records:
        lines += ["## Records", ""]
        for rel in records:
            record = info[rel]
            item = f"* [{record['title']}]({PurePosixPath(rel).name})"
            if record["description"] and not record["restricted"]:
                item += f" - {record['description']}"
            lines.append(item)
    return "\n".join(lines).rstrip() + "\n"


def _bf_is_ours(path: Path) -> bool:
    try:
        with open(path, "rb") as stream:
            return stream.readline().rstrip(b"\r\n") == BACKFILL_MARKER.encode("utf-8")
    except OSError:
        return False


def _bf_index_plan(project: Path, info: dict[str, dict[str, Any]], only: set[str] | None, create: bool) -> tuple[list[tuple[str, str, str]], dict[str, int]]:
    folders = _bf_folders(project, info)
    plan: list[tuple[str, str, str]] = []
    counts = {"folders": len(folders), "index_create": 0, "index_refresh": 0, "index_user_kept": 0, "index_current": 0}
    for folder in folders:
        if only is not None and folder not in only:
            continue
        target = project / folder / "index.md"
        text = _bf_index_text(folder, folders, info)
        if target.exists() or target.is_symlink():
            if not _bf_is_ours(target):
                counts["index_user_kept"] += 1
                continue
            if target.read_bytes() == text.encode("utf-8"):
                counts["index_current"] += 1
                continue
            counts["index_refresh"] += 1
            plan.append((folder, "refresh", text))
        elif create:
            counts["index_create"] += 1
            plan.append((folder, "create", text))
    return plan, counts


def _bf_print(prefix: str, counts: dict[str, int]) -> None:
    print(prefix + " " + " ".join(f"{key}={value}" for key, value in counts.items()))


def command_okf_backfill(args: argparse.Namespace) -> int:
    project = Path(os.path.realpath(args.project_dir))
    if not (project / "okf").is_dir():
        raise OkfError(f"project has no okf bundle: {project}")
    state_dir = project / BACKFILL_DIR
    active = state_dir / "active"
    if args.mode == "undo":
        return _bf_undo(project, state_dir, args.id)
    cache = RecordCache(project)
    scan = _bf_scan(project, cache)
    cache.save()
    if args.mode == "refresh":
        if not active.is_file():
            print("okf_backfill=refresh state=inactive")
            return 0
        only = None
        if args.folder:
            only = set()
            parent = PurePosixPath(args.folder)
            while parent.as_posix() not in ("okf", "."):
                only.add(parent.as_posix())
                parent = parent.parent
        plan, counts = _bf_index_plan(project, scan["info"], only, create=True)
        for folder, _action, text in plan:
            target = project / folder / "index.md"
            if target.exists() and not _bf_is_ours(target):
                continue
            _bf_atomic_write(target, text.encode("utf-8"), None, None)
        _bf_print("okf_backfill=refresh", counts)
        return 0
    index_plan, index_counts = _bf_index_plan(project, scan["info"], None, create=True)
    if args.mode == "check":
        _bf_print("okf_backfill=check", {**scan["counts"], **index_counts})
        for plan in scan["plans"][: max(0, args.samples)]:
            print(f"okf_backfill:sample path={plan['rel']} description={json.dumps(plan['description'], ensure_ascii=False)}")
        return 0
    # apply
    if not re.fullmatch(r"okfbf-[A-Za-z0-9-]{1,64}", args.id or ""):
        raise OkfError("apply requires --id okfbf-...")
    run_dir = state_dir / args.id
    run_dir.mkdir(parents=True, exist_ok=False)
    preexisting_ours = sorted(
        p.relative_to(project).as_posix() for p in (project / "okf").rglob("index.md") if p.parent != project / "okf" and _bf_is_ours(p)
    )
    manifest = {
        "format": 1, "id": args.id, "state": "in-progress", "created_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "edits": [{k: p[k] for k in ("rel", "offset", "insert", "before_sha", "after_sha")} for p in scan["plans"]],
        "index_created": [f"{folder}/index.md" for folder, action, _ in index_plan if action == "create"],
        "index_refreshed": [{"rel": f"{folder}/index.md", "before": (project / folder / "index.md").read_text(encoding="utf-8")} for folder, action, _ in index_plan if action == "refresh"],
        "preexisting_generated": preexisting_ours,
        "skipped_changed": [],
    }
    manifest_path = run_dir / "manifest.json"

    def save_manifest() -> None:
        _bf_atomic_write(manifest_path, (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode("utf-8"), 0o644, None)

    save_manifest()  # journal first: an interrupted apply is still undoable
    _bf_atomic_write(active, (args.id + "\n").encode("utf-8"), 0o644, None)
    applied = 0
    for edit in manifest["edits"]:
        path = project / edit["rel"]
        st = os.lstat(path)
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != edit["before_sha"]:
            manifest["skipped_changed"].append(edit["rel"])
            continue
        offset, insert = edit["offset"], edit["insert"].encode("utf-8")
        if not _bf_atomic_write(path, raw[:offset] + insert + raw[offset:], st.st_mode, st):
            manifest["skipped_changed"].append(edit["rel"])
            continue
        applied += 1
    manifest["edits"] = [e for e in manifest["edits"] if e["rel"] not in set(manifest["skipped_changed"])]
    for folder, action, text in index_plan:
        target = project / folder / "index.md"
        if action == "create" and (target.exists() or target.is_symlink()):
            continue
        _bf_atomic_write(target, text.encode("utf-8"), 0o644 if action == "create" else None, None)
    manifest["state"] = "applied"
    save_manifest()
    print(
        f"okf_backfill=applied id={args.id} descriptions={applied} skipped_changed={len(manifest['skipped_changed'])} "
        f"index_created={len(manifest['index_created'])} index_refreshed={len(manifest['index_refreshed'])} "
        f"manifest={manifest_path.relative_to(project).as_posix()} manifest_sha256={hashlib.sha256(manifest_path.read_bytes()).hexdigest()}"
    )
    return 0


def command_describe_new(args: argparse.Namespace) -> int:
    """Insert an OKF `description:` into a freshly written (not yet canonical)
    record file, using exactly the okf-backfill rules: restricted, secret,
    non-internal or principal/audience-scoped records, retractions, records
    that already have one and bodies with no lead sentence are left
    byte-for-byte alone.  Prints the outcome key; always exits 0 unless the
    file cannot be read (the caller then keeps the file as it is)."""
    path = Path(args.file)
    raw = path.read_bytes()
    entry: dict[str, Any] = {"raw": raw, "sha": hashlib.sha256(raw).hexdigest()}
    try:
        text = raw.decode("utf-8")
        meta, body = split_frontmatter_text(text)
        entry["meta"] = meta
        entry["body_at"] = len(text) - len(body)
    except (UnicodeDecodeError, OkfError) as exc:
        entry["err"] = str(exc)
    key, _record, plan = _bf_one(path, args.rel or path.name, entry)
    if plan is not None:
        offset = plan["offset"]
        new_raw = raw[:offset] + plan["insert"].encode("utf-8") + raw[offset:]
        temp = path.with_name(path.name + ".desc")
        temp.write_bytes(new_raw)
        os.chmod(temp, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(temp, path)
    print(key)
    return 0


def _bf_undo(project: Path, state_dir: Path, run_id: str | None) -> int:
    if not re.fullmatch(r"okfbf-[A-Za-z0-9-]{1,64}", run_id or ""):
        raise OkfError("undo requires --id okfbf-...")
    manifest_path = state_dir / run_id / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("state") == "undone":
        print(f"okf_backfill=undo id={run_id} state=already-undone")
        return 0
    restores: list[tuple[Path, bytes, os.stat_result]] = []
    conflicts = already = 0
    for edit in manifest["edits"]:
        path = project / edit["rel"]
        try:
            st = os.lstat(path)
            raw = path.read_bytes()
        except OSError:
            conflicts += 1
            continue
        sha = hashlib.sha256(raw).hexdigest()
        if sha == edit["before_sha"]:
            already += 1
            continue
        insert = edit["insert"].encode("utf-8")
        offset = edit["offset"]
        original = raw[:offset] + raw[offset + len(insert):]
        if sha != edit["after_sha"] or raw[offset:offset + len(insert)] != insert or hashlib.sha256(original).hexdigest() != edit["before_sha"]:
            conflicts += 1
            continue
        restores.append((path, original, st))
    if conflicts:
        print(f"okf_backfill=undo id={run_id} state=refused conflicts={conflicts} (records edited after the backfill; nothing changed)")
        return 75
    for path, original, st in restores:
        if not _bf_atomic_write(path, original, st.st_mode, st):
            print(f"okf_backfill=undo id={run_id} state=partial reason=record-changed-during-undo")
            return 75
    for item in manifest.get("index_refreshed", []):
        target = project / item["rel"]
        if _bf_is_ours(target):
            _bf_atomic_write(target, item["before"].encode("utf-8"), None, None)
    keep = set(manifest.get("preexisting_generated", [])) | {i["rel"] for i in manifest.get("index_refreshed", [])}
    removed = 0
    for path in sorted((project / "okf").rglob("index.md")):
        rel = path.relative_to(project).as_posix()
        if path.parent != project / "okf" and rel not in keep and _bf_is_ours(path):
            path.unlink()
            removed += 1
    active = state_dir / "active"
    if active.is_file() and active.read_text(encoding="utf-8").strip() == run_id:
        active.unlink()
    manifest["state"] = "undone"
    manifest["undone_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _bf_atomic_write(manifest_path, (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode("utf-8"), 0o644, None)
    print(f"okf_backfill=undone id={run_id} restored={len(restores)} already_original={already} index_removed={removed}")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-bundle")
    validate.add_argument("bundle")
    validate.set_defaults(func=command_validate)

    facts = commands.add_parser("facts")
    facts.add_argument("file")
    facts.set_defaults(func=command_facts)

    facts_batch = commands.add_parser("facts-batch")
    facts_batch.add_argument("paths_file")
    facts_batch.add_argument("--project-root", required=True)
    facts_batch.add_argument("--snapshot-root", required=True)
    facts_batch.set_defaults(func=command_facts_batch)

    field = commands.add_parser("field")
    field.add_argument("file")
    field.add_argument("key")
    field.set_defaults(func=command_field)

    valid_batch = commands.add_parser("valid-batch")
    valid_batch.add_argument("paths_file")
    valid_batch.set_defaults(func=command_valid_batch)

    facts_list = commands.add_parser("facts-list")
    facts_list.add_argument("paths_file")
    facts_list.set_defaults(func=command_facts_list)

    dependency_snapshot = commands.add_parser("dependency-snapshot")
    dependency_snapshot.add_argument("root")
    dependency_snapshot.add_argument("--refs", default="")
    dependency_snapshot.add_argument("--principal", default="")
    dependency_snapshot.add_argument("--as-of", default="")
    dependency_snapshot.set_defaults(func=command_dependency_snapshot)

    lifecycle_bundle = commands.add_parser("lifecycle-bundle")
    lifecycle_bundle.add_argument("root")
    lifecycle_bundle.add_argument("file")
    lifecycle_bundle.add_argument("--principal", default="")
    lifecycle_bundle.add_argument("--as-of", default="")
    lifecycle_bundle.add_argument("--roots", default="")
    lifecycle_bundle.add_argument("--max-records", type=int, default=20)
    lifecycle_bundle.set_defaults(func=command_lifecycle_bundle)

    migrate = commands.add_parser("migrate-concept")
    migrate.add_argument("file")
    migrate.add_argument("--actor", required=True)
    migrate.add_argument("--at", required=True)
    migrate.add_argument("--type-hint")
    migrate.set_defaults(func=command_migrate_concept)

    bundle = commands.add_parser("migrate-bundle")
    bundle.add_argument("bundle")
    bundle.add_argument("--project-id", required=True)
    bundle.add_argument("--title", required=True)
    bundle.add_argument("--actor", required=True)
    bundle.add_argument("--at", required=True)
    bundle.set_defaults(func=command_migrate_bundle)

    audit_verify = commands.add_parser("audit-verify")
    audit_verify.add_argument("file")
    audit_verify.set_defaults(func=command_audit_verify)
    audit = commands.add_parser("audit")
    audit.add_argument("bundle")
    audit.add_argument("--json", action="store_true")
    audit.set_defaults(func=command_audit)

    bundle_hash = commands.add_parser("bundle-hash")
    bundle_hash.add_argument("bundle")
    bundle_hash.set_defaults(func=command_hash)

    plugin_info = commands.add_parser("plugin-info")
    plugin_info.add_argument("json_file")
    plugin_info.add_argument("name")
    plugin_info.set_defaults(func=command_plugin_info)

    manifest_info = commands.add_parser("manifest-info")
    manifest_info.add_argument("json_file")
    manifest_info.set_defaults(func=command_manifest_info)
    backfill = commands.add_parser("okf-backfill")
    backfill.add_argument("--project-dir", required=True)
    backfill.add_argument("--mode", choices=("check", "apply", "undo", "refresh"), default="check")
    backfill.add_argument("--id")
    backfill.add_argument("--samples", type=int, default=3)
    backfill.add_argument("--folder")
    backfill.set_defaults(func=command_okf_backfill)
    describe = commands.add_parser("describe-new")
    describe.add_argument("--file", required=True)
    describe.add_argument("--rel")
    describe.set_defaults(func=command_describe_new)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.func(args))
    except OkfError as exc:
        print(f"okf:error {exc}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
