#!/usr/bin/env python3
"""Strict OKF v0.2 parsing and schema-3 migration support for LLM-Brain."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
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
