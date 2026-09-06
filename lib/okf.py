#!/usr/bin/env python3
"""Strict OKF v0.2 parsing and schema-3 migration support for LLM-Brain."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised by upgrade bootstrap tests
    raise SystemExit(
        "llm-brain: PyYAML is unavailable; run `llm-brain upgrade check` "
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


def validate_bundle(root: Path) -> tuple[list[tuple[Path, str]], int]:
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
                metadata, body = split_frontmatter(path)
                current = concept_issues(metadata, body)
            except OkfError as exc:
                current = [str(exc)]
        issues.extend((path.relative_to(root), issue) for issue in current)
    return issues, concepts


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
    issues, concepts = validate_bundle(root)
    for path, issue in issues:
        print(f"okf:error path={path.as_posix()} issue={issue}")
    print(
        f"okf bundle={root} version={OKF_VERSION} concepts={concepts} "
        f"errors={len(issues)}"
    )
    return 1 if issues else 0


def command_facts(args: argparse.Namespace) -> int:
    metadata, _ = split_frontmatter(Path(args.file))
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
    print(
        "\t".join(
            (value or "none").replace("\t", " ").replace("\n", " ")
            for value in values
        )
    )
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
                    resolved = candidate.resolve()
                    resolved.relative_to(self.root)
                except (OSError, ValueError):
                    continue
                if resolved.is_file():
                    files.append(resolved)
        self.files = sorted(set(files))
        self.file_set = set(self.files)
        # Parse once per request so reverse expansion and state resolution see
        # one stable view and malformed records fail closed consistently.
        for path in self.files:
            self.load(path)

    def load(self, path: Path) -> dict[str, Any]:
        try:
            path = path.resolve()
        except OSError:
            return {}
        if path not in self.metadata:
            try:
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
        return path.resolve().relative_to(self.root).as_posix()

    def _record_sensitivity(self, path: Path) -> str:
        metadata = self.load(path)
        value = metadata.get("brain_sensitivity", metadata.get("sensitivity", "internal"))
        if value is None:
            return "internal"
        return value if isinstance(value, str) else "invalid"

    def visible(self, path: Path, *, strict_principal: bool = True) -> bool:
        try:
            path = path.resolve()
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
        if not identities:
            return True
        if not self.principal:
            return not strict_principal
        return self.principal in identities

    def effective(self, path: Path) -> bool:
        try:
            path = path.resolve()
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
            candidate_path = (self.root / text).resolve()
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
            path = path.resolve()
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
                resolved = candidate.resolve()
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
                path = path.resolve()
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


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-bundle")
    validate.add_argument("bundle")
    validate.set_defaults(func=command_validate)

    facts = commands.add_parser("facts")
    facts.add_argument("file")
    facts.set_defaults(func=command_facts)

    field = commands.add_parser("field")
    field.add_argument("file")
    field.add_argument("key")
    field.set_defaults(func=command_field)

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
