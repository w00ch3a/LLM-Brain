#!/usr/bin/env python3
"""Ground-truth-first longitudinal evaluation for LLM-Brain.

The case file is deliberately data-only.  The runner owns the small allow-list
of lifecycle operations and creates a temporary vault for every family and
horizon.  An answer runner receives only a question and selected evidence as
the first JSON argument and an output path as the second argument; expected
paths and fixture truth never enter that request.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


FORMAT = "llm-brain.lifecycle-evaluation"
VERSION = 1
MODES = ("none", "raw-source", "factual", "explicit", "evidence", "historical")
MODE_INTENTS = {
    "factual": "factual",
    "explicit": "current_state",
    "evidence": "evidence",
    "historical": "historical",
}
OPERATIONS = {
    "capture",
    "review",
    "supersession",
    "retraction",
    "retrieval",
    "prepare",
    "validate",
}
HORIZONS = (20, 200)
MAX_CASE_BYTES = 10 * 1024 * 1024
MAX_FAMILIES = 64
MAX_RECORDS = 256
MAX_QUERY_BYTES = 65536
MAX_EVIDENCE_BYTES = 16000
MAX_OUTPUT_BYTES = 1024 * 1024
EVALUATION_BUDGET_TOKENS = MAX_EVIDENCE_BYTES // 4
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")
PATH_RE = re.compile(r"^(?:okf|sources|episodes|review|runs)(?:/[A-Za-z0-9_.-]+)+\.md$")
NON_MEMORY_PATHS = {"okf/project.md"}


class EvaluationError(Exception):
    """A bounded input or lifecycle failure."""


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def scalar(value: Any) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def safe_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or not ID_RE.fullmatch(value):
        raise EvaluationError(f"{label} must be a short identifier")
    return value


def single_line(value: Any, label: str, limit: int = MAX_QUERY_BYTES) -> str:
    if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
        raise EvaluationError(f"{label} must be a non-empty single line")
    if len(value.encode("utf-8")) > limit:
        raise EvaluationError(f"{label} is too large")
    return value.strip()


def relative_ref(value: Any, label: str) -> str:
    ref = single_line(value, label)
    if ref.startswith("/") or ".." in ref.split("/") or not PATH_RE.fullmatch(ref):
        raise EvaluationError(f"{label} must be a relative Markdown reference")
    return ref


def read_json(path: Path) -> Any:
    if not path.is_file() or path.is_symlink():
        raise EvaluationError(f"cases file is not a regular file: {path}")
    if path.stat().st_size > MAX_CASE_BYTES:
        raise EvaluationError("cases file is too large")

    def reject_constant(value: str) -> None:
        raise EvaluationError(f"invalid JSON constant: {value}")

    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"invalid cases JSON: {exc}") from exc


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command(
    argv: list[str],
    *,
    timeout: int = 60,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvaluationError(f"command failed to start or timed out: {argv[0]}: {exc}") from exc


def repository_revision(repo_root: Path) -> str:
    result = command(["git", "-C", str(repo_root), "rev-parse", "HEAD"], timeout=10)
    revision = result.stdout.strip()
    return revision if result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", revision) else "unresolved"


@dataclass
class Query:
    query_id: str
    text: str
    expected_paths: list[str]
    source_expected: bool
    source_event_ids: list[str]
    forbidden_paths: list[str]
    visibility_forbidden_paths: list[str]
    future_paths: list[str]
    expected_states: dict[str, str]
    require_unresolved: bool
    require_provenance: bool
    require_independent_sources: int | None
    require_repair: bool
    require_capsule_validation: bool
    as_of: str | None
    principal: str | None
    expected_answer: str | None
    historical_expected_paths: list[str]
    historical_relevant: bool
    poisoned_paths: list[str]


@dataclass
class Family:
    family_id: str
    description: str
    ground_truth: dict[str, Any]
    events: list[dict[str, Any]]
    queries: list[Query]
    horizons: list[int]


@dataclass
class Candidate:
    path: str
    rank: int
    score: str = ""
    state: str = ""
    title: str = ""
    evidence_group: str = ""
    provenance_state: str = ""


@dataclass
class RuntimeState:
    capsules: dict[str, str] = field(default_factory=dict)
    event_results: list[dict[str, Any]] = field(default_factory=list)
    retrieval_checkpoints: list[dict[str, Any]] = field(default_factory=list)
    pending_capture_files: list[Path] = field(default_factory=list)
    pending_capture_ids: dict[str, str] = field(default_factory=dict)
    capture_paths: dict[str, str] = field(default_factory=dict)
    checkpoint_rows: list[dict[str, Any]] = field(default_factory=list)
    operation_counts: Counter[str] = field(default_factory=Counter)
    operation_elapsed_ms: Counter[str] = field(default_factory=Counter)
    operation_writes: Counter[str] = field(default_factory=Counter)
    operation_write_bytes: Counter[str] = field(default_factory=Counter)
    write_cost: int = 0
    write_bytes: int = 0
    seed_write_cost: int = 0
    seed_write_bytes: int = 0
    capsule_validated: bool = False
    capsule_validation_results: list[dict[str, Any]] = field(default_factory=list)
    repair_results: list[dict[str, Any]] = field(default_factory=list)
    record_texts: dict[str, str] = field(default_factory=dict)


def normalise_record(raw: Any, family_id: str, *, event_id: str | None = None) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise EvaluationError(f"{family_id}: record must be an object")
    record_id = safe_id(raw.get("id"), f"{family_id} record id")
    kind = raw.get("kind", "claim")
    if kind not in {"claim", "procedure", "reference", "topic"}:
        raise EvaluationError(f"{family_id}/{record_id}: unsupported record kind")
    title = single_line(raw.get("title", record_id), f"{family_id}/{record_id} title")
    text = single_line(raw.get("text", title), f"{family_id}/{record_id} text", 128 * 1024)
    directory = {"claim": "claims", "procedure": "procedures", "reference": "references", "topic": "topics"}[kind]
    path = raw.get("path", f"okf/{directory}/{record_id}.md")
    path = relative_ref(path, f"{family_id}/{record_id} path")
    if not path.startswith(f"okf/{directory}/"):
        raise EvaluationError(f"{family_id}/{record_id}: path does not match kind")
    item = dict(raw)
    item.update({"id": record_id, "kind": kind, "title": title, "text": text, "path": path})
    if event_id:
        item["event_id"] = event_id
    return item


def parse_cases(payload: Any) -> tuple[list[Family], dict[str, Any]]:
    if not isinstance(payload, dict) or payload.get("format") != FORMAT or payload.get("version") != VERSION:
        raise EvaluationError(f"cases must declare {FORMAT} version {VERSION}")
    raw_horizons = payload.get("horizons", list(HORIZONS))
    if not isinstance(raw_horizons, list) or not raw_horizons:
        raise EvaluationError("cases horizons must be a non-empty list")
    horizons: list[int] = []
    for horizon in raw_horizons:
        if not isinstance(horizon, int) or isinstance(horizon, bool) or not 1 <= horizon <= 200:
            raise EvaluationError("each horizon must be an integer from 1 to 200")
        if horizon not in horizons:
            horizons.append(horizon)
    raw_families = payload.get("scenario_families")
    if not isinstance(raw_families, list) or not raw_families or len(raw_families) > MAX_FAMILIES:
        raise EvaluationError("cases must contain between 1 and 64 scenario families")

    families: list[Family] = []
    seen_ids: set[str] = set()
    for raw_family in raw_families:
        if not isinstance(raw_family, dict):
            raise EvaluationError("scenario family must be an object")
        family_id = safe_id(raw_family.get("id"), "scenario family id")
        if family_id in seen_ids:
            raise EvaluationError(f"duplicate scenario family: {family_id}")
        seen_ids.add(family_id)
        description = single_line(raw_family.get("description", family_id), f"{family_id} description", 1024)
        truth = raw_family.get("ground_truth")
        if not isinstance(truth, dict):
            raise EvaluationError(f"{family_id}: ground_truth must be an object")
        raw_records = truth.get("records", [])
        if not isinstance(raw_records, list) or len(raw_records) > MAX_RECORDS:
            raise EvaluationError(f"{family_id}: ground_truth.records must be a bounded list")
        record_ids: set[str] = set()
        records: list[dict[str, Any]] = []
        for raw_record in raw_records:
            record = normalise_record(raw_record, family_id)
            if record["id"] in record_ids:
                raise EvaluationError(f"{family_id}: duplicate record {record['id']}")
            record_ids.add(record["id"])
            records.append(record)
        truth = dict(truth)
        truth["records"] = records

        raw_queries = truth.get("queries", raw_family.get("queries", []))
        if not isinstance(raw_queries, list) or not raw_queries:
            raise EvaluationError(f"{family_id}: ground_truth.queries must be non-empty")
        queries: list[Query] = []
        query_ids: set[str] = set()
        for raw_query in raw_queries:
            if not isinstance(raw_query, dict):
                raise EvaluationError(f"{family_id}: query must be an object")
            query_id = safe_id(raw_query.get("id"), f"{family_id} query id")
            if query_id in query_ids:
                raise EvaluationError(f"{family_id}: duplicate query {query_id}")
            query_ids.add(query_id)
            text = single_line(raw_query.get("text"), f"{family_id}/{query_id} text")
            expected = raw_query.get("expected_paths", [])
            if not isinstance(expected, list):
                raise EvaluationError(f"{family_id}/{query_id}: expected_paths must be a list")
            def resolve_ref(ref: str, label: str) -> str:
                matching = next((r["path"] for r in records if ref in {r["id"], r["path"]}), None)
                if matching:
                    return matching
                if ID_RE.fullmatch(ref):
                    return f"okf/claims/{ref}.md"
                return relative_ref(ref, label)

            expected_paths = []
            for ref in expected:
                if not isinstance(ref, str):
                    raise EvaluationError(f"{family_id}/{query_id}: expected path must be text")
                expected_paths.append(resolve_ref(ref, f"{family_id}/{query_id} expected path"))
            def query_refs(name: str) -> list[str]:
                raw_refs = raw_query.get(name, [])
                if not isinstance(raw_refs, list):
                    raise EvaluationError(f"{family_id}/{query_id}: {name} must be a list")
                resolved: list[str] = []
                for ref in raw_refs:
                    if not isinstance(ref, str):
                        raise EvaluationError(f"{family_id}/{query_id}: {name} entries must be text")
                    resolved.append(resolve_ref(ref, f"{family_id}/{query_id} {name} entry"))
                return resolved

            source_event_ids = raw_query.get("source_event_ids", [])
            if not isinstance(source_event_ids, list) or any(not isinstance(value, str) or not ID_RE.fullmatch(value) for value in source_event_ids):
                raise EvaluationError(f"{family_id}/{query_id}: source_event_ids must be short identifiers")
            forbidden_paths = query_refs("forbidden_paths")
            visibility_forbidden_paths = query_refs("visibility_forbidden_paths")
            future_paths = query_refs("future_paths")
            historical_expected_paths = query_refs("historical_expected_paths")
            poisoned_paths = query_refs("poisoned_paths")
            raw_states = raw_query.get("expected_states", {})
            if not isinstance(raw_states, dict):
                raise EvaluationError(f"{family_id}/{query_id}: expected_states must be an object")
            expected_states: dict[str, str] = {}
            for ref, state in raw_states.items():
                expected_states[resolve_ref(ref, f"{family_id}/{query_id} expected state path")] = single_line(state, f"{family_id}/{query_id} expected state", 128)
            raw_independent = raw_query.get("require_independent_sources")
            if raw_independent is not None and (not isinstance(raw_independent, int) or isinstance(raw_independent, bool) or raw_independent < 0):
                raise EvaluationError(f"{family_id}/{query_id}: require_independent_sources must be non-negative")
            as_of = raw_query.get("as_of")
            if as_of is not None:
                as_of = single_line(as_of, f"{family_id}/{query_id} as_of", 64)
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", as_of):
                    raise EvaluationError(f"{family_id}/{query_id}: as_of must be ISO UTC")
            principal = raw_query.get("principal")
            if principal is not None:
                principal = single_line(principal, f"{family_id}/{query_id} principal", 256)
            expected_answer = raw_query.get("expected_answer")
            if expected_answer is not None:
                expected_answer = single_line(expected_answer, f"{family_id}/{query_id} expected_answer", 128 * 1024)
            queries.append(
                Query(
                    query_id,
                    text,
                    expected_paths,
                    bool(raw_query.get("source_expected", True)),
                    source_event_ids,
                    forbidden_paths,
                    visibility_forbidden_paths,
                    future_paths,
                    expected_states,
                    bool(raw_query.get("require_unresolved", False)),
                    bool(raw_query.get("require_provenance", False)),
                    raw_independent,
                    bool(raw_query.get("require_repair", False)),
                    bool(raw_query.get("require_capsule_validation", False)),
                    as_of,
                    principal,
                    expected_answer,
                    historical_expected_paths,
                    bool(raw_query.get("historical_relevant", False)),
                    poisoned_paths,
                )
            )
        truth["queries"] = raw_queries

        raw_events = raw_family.get("events", [])
        if not isinstance(raw_events, list):
            raise EvaluationError(f"{family_id}: events must be a list")
        events: list[dict[str, Any]] = []
        for index, raw_event in enumerate(raw_events):
            if not isinstance(raw_event, dict):
                raise EvaluationError(f"{family_id}: event {index} must be an object")
            operation = raw_event.get("operation")
            operation = {
                "replacement": "supersession",
                "preparation": "prepare",
                "validation": "validate",
            }.get(operation, operation)
            if operation not in OPERATIONS:
                raise EvaluationError(f"{family_id}: event {index} has unsupported operation {operation!r}")
            event = dict(raw_event)
            event["operation"] = operation
            if "command" in event or "shell" in event:
                raise EvaluationError(f"{family_id}: event {index} cannot contain command or shell data")
            events.append(event)
        capture_ids = {
            safe_id(event.get("id", f"capture-{index}"), f"{family_id} capture id")
            for index, event in enumerate(events)
            if event["operation"] == "capture"
        }
        for query in queries:
            missing = sorted(set(query.source_event_ids) - capture_ids)
            if missing:
                raise EvaluationError(f"{family_id}/{query.query_id}: unknown source_event_ids: {', '.join(missing)}")
        family_horizons = raw_family.get("horizons", horizons)
        if not isinstance(family_horizons, list) or not family_horizons:
            raise EvaluationError(f"{family_id}: horizons must be a non-empty list")
        family_horizon_values: list[int] = []
        for horizon in family_horizons:
            if horizon not in horizons:
                raise EvaluationError(f"{family_id}: horizon {horizon} is not in top-level horizons")
            if horizon not in family_horizon_values:
                family_horizon_values.append(horizon)
        families.append(Family(family_id, description, truth, events, queries, family_horizon_values))
    return families, payload


def record_fields(record: dict[str, Any], project_id: str) -> dict[str, Any]:
    fields: dict[str, Any] = {
        "type": {"claim": "Claim", "procedure": "Procedure", "reference": "Reference", "topic": "Topic"}[record["kind"]],
        "title": record["title"],
        "status": record.get("status", "stable"),
        "brain_project_id": project_id,
        "brain_review_state": record.get("review_state", "approved"),
        "brain_confidence": record.get("confidence", "0.99"),
        "brain_risk": record.get("risk", "low"),
        "brain_sensitivity": record.get("sensitivity", "internal"),
        "brain_source_authority": record.get("source_authority", "repository"),
        "brain_authority_origin": record.get("authority_origin", "repository"),
        "brain_provenance": record.get("provenance", "human://lifecycle-evaluation"),
        "brain_schema_version": 3,
        "brain_valid_from": record.get("valid_from", "2020-01-01T00:00:00Z"),
        "brain_valid_to": record.get("valid_to", "2035-01-01T00:00:00Z"),
    }
    identifier_field = {
        "claim": "brain_claim_id",
        "procedure": "brain_procedure_id",
        "reference": "brain_reference_id",
        "topic": "brain_topic_id",
    }[record["kind"]]
    fields[identifier_field] = record["id"]
    for name in (
        "state_key",
        "depends_on",
        "supersedes",
        "version_of",
        "conflicts",
        "supports",
        "derived_from",
        "contradicts",
        "merged_from",
        "principal",
        "audience",
        "required_bindings",
        "applicability",
        "prerequisites",
        "verification",
        "source_ref",
        "source_hash_sha256",
    ):
        if name in record:
            fields[f"brain_{name}"] = record[name]
    if record.get("kind") == "procedure" and "required_bindings" not in record:
        fields["brain_required_bindings"] = "none"
    return fields


def render_yaml_value(value: Any) -> str:
    if isinstance(value, list):
        return "[" + ", ".join(scalar(item) for item in value) + "]"
    if isinstance(value, dict):
        return scalar(json.dumps(value, sort_keys=True))
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if value is None:
        return scalar("")
    text = str(value)
    if text in {"stable", "approved", "low", "medium", "high", "internal", "repository", "human-directive", "external-observation", "none"} and re.fullmatch(r"[A-Za-z0-9_.-]+", text):
        return text
    return scalar(text)


def write_canonical(project_dir: Path, record: dict[str, Any], project_id: str, *, event_id: str | None = None) -> Path:
    record = normalise_record(record, record.get("family_id", "record"), event_id=event_id)
    destination = project_dir / record["path"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise EvaluationError(f"canonical fixture already exists: {record['path']}")
    fields = record_fields(record, project_id)
    lines = ["---"]
    for key, value in fields.items():
        lines.append(f"{key}: {render_yaml_value(value)}")
    lines.extend(["---", f"# {record['title']}", "", record["text"], ""])
    destination.write_text("\n".join(lines), encoding="utf-8")
    return destination


def write_candidate(path: Path, record: dict[str, Any], project_id: str) -> None:
    fields = record_fields(record, project_id)
    fields.update(
        {
            "type": "ReviewItem",
            "brain_candidate_id": record["id"],
            "brain_review_kind": record["kind"],
            "brain_review_state": "proposed",
            "brain_provider_id": "lifecycle-fixture",
            "brain_provider_version": "1",
            "brain_provenance": "human://lifecycle-evaluation",
        }
    )
    lines = ["---"]
    for key, value in fields.items():
        lines.append(f"{key}: {render_yaml_value(value)}")
    lines.extend(["---", f"# {record['title']}", "", record["text"], ""])
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_key_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for token in text.replace("\n", " ").split():
        if "=" in token:
            key, value = token.split("=", 1)
            if key and key.replace("-", "_").isidentifier():
                values[key] = value
    return values


def cli_base(cli: Path, vault: Path) -> list[str]:
    return [str(cli), "--root", str(vault)]


def run_cli(cli: Path, vault: Path, args: list[str], *, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    result = command(cli_base(cli, vault) + args, timeout=timeout)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().replace("\n", " ")
        raise EvaluationError(f"llm-brain {' '.join(args[:3])} failed ({result.returncode}): {detail[:500]}")
    return result


def file_snapshot(root: Path) -> dict[str, tuple[str, int]]:
    """Return a bounded, hash-based view for measuring real fixture writes."""
    snapshot: dict[str, tuple[str, int]] = {}
    if not root.exists():
        return snapshot
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            relative = str(path.relative_to(root))
            data = path.read_bytes()
        except (OSError, ValueError):
            continue
        snapshot[relative] = (digest_bytes(data), len(data))
    return snapshot


def snapshot_delta(before: dict[str, tuple[str, int]], after: dict[str, tuple[str, int]]) -> tuple[int, int]:
    changed = 0
    bytes_written = 0
    for path, value in after.items():
        if before.get(path) != value:
            changed += 1
            bytes_written += value[1]
    return changed, bytes_written


def write_capture_file(capture_dir: Path, family_id: str, event_index: int, event: dict[str, Any]) -> Path:
    event_id = safe_id(event.get("id", f"capture-{event_index}"), f"{family_id} capture id")
    text = single_line(event.get("text", f"Synthetic source event {family_id} {event_id}"), f"{family_id}/{event_id} source text", 128 * 1024)
    path = capture_dir / f"{event_index:04d}-{event_id}.md"
    path.write_text(text + "\n", encoding="utf-8")
    return path


def flush_captures(cli: Path, vault: Path, repo_root: Path, project_id: str, runtime: RuntimeState) -> None:
    if not runtime.pending_capture_files:
        return
    capture_dir = runtime.pending_capture_files[0].parent
    started = time.monotonic()
    result = run_cli(
        cli,
        vault,
        ["bridge", "capture", "--source-root", str(repo_root), "--project-id", project_id, "--record-dir", str(capture_dir)],
        timeout=120,
    )
    count = len(runtime.pending_capture_files)
    project_dir = vault / "projects" / project_id
    for capture_path in runtime.pending_capture_files:
        source_hash = digest_file(capture_path)
        safe_name = re.sub(r"[^a-z0-9]+", "-", capture_path.name.lower()).strip("-") or "item"
        destination = project_dir / "sources" / f"{source_hash}-{safe_name}.md"
        if not destination.is_file():
            matches = sorted((project_dir / "sources").glob(f"{source_hash}*.md"))
            if matches:
                destination = matches[0]
        event_id = runtime.pending_capture_ids.get(capture_path.name)
        if event_id and destination.is_file():
            runtime.capture_paths[event_id] = str(destination.relative_to(project_dir))
        elif event_id:
            raise EvaluationError(f"capture custody missing for event {event_id}")
    elapsed = (time.monotonic() - started) * 1000
    runtime.operation_elapsed_ms["capture"] += elapsed
    runtime.event_results.append({"operation": "capture-batch", "status": "ok", "count": count, "elapsed_ms": round(elapsed, 3), "output": result.stdout.strip()[-200:]})
    runtime.pending_capture_files.clear()
    runtime.pending_capture_ids.clear()


def build_index(cli: Path, vault: Path, project_id: str) -> None:
    run_cli(cli, vault, ["index", "build", project_id], timeout=120)


def parse_capsule_path(output: str, project_dir: Path) -> str:
    values = parse_key_values(output)
    path = values.get("file")
    if not path and values.get("capsule_id"):
        path = str(project_dir / "runs" / "prepared" / f"{values['capsule_id']}.md")
    if not path:
        raise EvaluationError("run prepare did not return a capsule file")
    try:
        return str(Path(path).resolve().relative_to(project_dir.resolve()))
    except ValueError as exc:
        raise EvaluationError("run prepare returned a capsule outside the disposable project") from exc


def apply_event(
    cli: Path,
    vault: Path,
    repo_root: Path,
    project_id: str,
    project_dir: Path,
    family: Family,
    event: dict[str, Any],
    index: int,
    capture_dir: Path,
    runtime: RuntimeState,
    record_ids: dict[str, str],
) -> None:
    operation = event["operation"]
    runtime.operation_counts[operation] += 1
    if operation == "capture":
        capture_path = write_capture_file(capture_dir, family.family_id, index, event)
        runtime.pending_capture_files.append(capture_path)
        runtime.pending_capture_ids[capture_path.name] = safe_id(event.get("id", f"capture-{index}"), f"{family.family_id} capture id")
        return
    flush_captures(cli, vault, repo_root, project_id, runtime)
    if operation == "review":
        raw_record = event.get("record")
        record = normalise_record(raw_record, family.family_id, event_id=f"review-{index}")
        record_ids[record["id"]] = record["path"]
        candidate = capture_dir.parent / f"candidate-{record['id']}.md"
        write_candidate(candidate, record, project_id)
        submitted = run_cli(cli, vault, ["reflect", "submit", project_id, str(candidate)])
        review_id = parse_key_values(submitted.stdout).get("review_id", record["id"])
        run_cli(cli, vault, ["review", "decide", project_id, review_id, "approved", "--actor", "human:lifecycle-evaluation", "--reason", "ground-truth fixture approval"])
        runtime.record_texts[record["path"]] = record["text"]
        runtime.event_results.append({"operation": operation, "status": "ok", "record": record["path"], "review_id": review_id})
        return
    if operation == "supersession":
        raw_record = event.get("record")
        record = normalise_record(raw_record, family.family_id, event_id=f"supersession-{index}")
        target = event.get("target")
        if not isinstance(target, str) or target not in record_ids:
            raise EvaluationError(f"{family.family_id}: replacement target must name a seeded record")
        record["supersedes"] = record_ids[target]
        record_ids[record["id"]] = record["path"]
        write_canonical(project_dir, record, project_id, event_id=f"supersession-{index}")
        runtime.record_texts[record["path"]] = record["text"]
        runtime.event_results.append({"operation": operation, "status": "ok", "record": record["path"], "supersedes": record_ids[target]})
        return
    if operation == "retraction":
        target = event.get("target")
        if not isinstance(target, str) or target not in record_ids:
            raise EvaluationError(f"{family.family_id}: retraction target must name a record")
        target_path = record_ids[target]
        target_file = project_dir / target_path
        before = file_snapshot(project_dir / "okf")
        authority_before = frontmatter_fields(target_file)
        run_cli(cli, vault, ["retract", project_id, Path(target_path).stem, "--reason", "synthetic lifecycle retraction"])
        after = file_snapshot(project_dir / "okf")
        target_hash_before = before.get(target_path)
        target_hash_after = after.get(target_path)
        unrelated_preserved = all(
            value == after.get(path)
            for path, value in before.items()
            if path != target_path
        )
        authority_after = frontmatter_fields(target_file)
        retraction_file = project_dir / "okf" / "retractions" / f"{Path(target_path).stem}.md"
        runtime.repair_results.append(
            {
                "target": target_path,
                "action_performed": retraction_file.is_file(),
                "authority_preserved": authority_before.get("brain_source_authority") == authority_after.get("brain_source_authority")
                and authority_before.get("brain_authority_origin") == authority_after.get("brain_authority_origin"),
                "unrelated_preserved": unrelated_preserved,
                "canonical_preserved": target_hash_before == target_hash_after,
                "source_custody_preserved": bool(runtime.capture_paths),
            }
        )
        runtime.event_results.append({"operation": operation, "status": "ok", "target": record_ids[target]})
        return
    if operation == "prepare":
        procedure = event.get("procedure")
        if not isinstance(procedure, str) or procedure not in record_ids:
            raise EvaluationError(f"{family.family_id}: preparation requires a known procedure record")
        task = single_line(event.get("task", "evaluate synthetic procedure"), f"{family.family_id} preparation task")
        args = ["run", "prepare", project_id, record_ids[procedure], "--task", task]
        principal = event.get("principal")
        if principal:
            args.extend(["--principal", single_line(principal, f"{family.family_id} preparation principal")])
        for binding in event.get("bindings", []):
            args.extend(["--binding", single_line(binding, f"{family.family_id} preparation binding")])
        if event.get("verification"):
            args.extend(["--verification", single_line(event["verification"], f"{family.family_id} preparation verification")])
        result = run_cli(cli, vault, args)
        capsule = parse_capsule_path(result.stdout, project_dir)
        runtime.capsules[event.get("name", procedure)] = capsule
        runtime.event_results.append({"operation": operation, "status": "ok", "procedure": record_ids[procedure], "capsule": capsule})
        return
    if operation == "validate":
        capsule_name = event.get("capsule") or event.get("procedure")
        capsule = runtime.capsules.get(str(capsule_name))
        if not capsule:
            raise EvaluationError(f"{family.family_id}: validation requires a prior preparation capsule")
        args = ["run", "validate", project_id, capsule, "--json"]
        principal = event.get("principal")
        if principal:
            args.extend(["--principal", single_line(principal, f"{family.family_id} validation principal")])
        result = run_cli(cli, vault, args)
        try:
            validation = json.loads(result.stdout)
        except json.JSONDecodeError:
            validation = {"status": "unknown", "raw": result.stdout.strip()[-500:]}
        status = validation.get("status") if isinstance(validation, dict) else None
        runtime.capsule_validated = runtime.capsule_validated or status == "valid"
        runtime.capsule_validation_results.append({"capsule": capsule, "status": status or "unknown"})
        runtime.event_results.append({"operation": operation, "status": "ok", "capsule": capsule, "output": result.stdout.strip()[-500:]})
        return
    if operation == "retrieval":
        build_index(cli, vault, project_id)
        query_id = safe_id(event.get("query_id"), f"{family.family_id} retrieval query id")
        runtime.retrieval_checkpoints.append({"query_id": query_id, "event_index": index, "status": "indexed"})
        runtime.event_results.append({"operation": operation, "status": "ok", "query_id": query_id})
        return
    raise EvaluationError(f"unsupported operation: {operation}")


def source_candidates(project_dir: Path, query: str) -> list[Candidate]:
    terms = [term for term in re.findall(r"[A-Za-z0-9]+", query.lower()) if len(term) > 2]
    ranked: list[tuple[str, int]] = []
    for path in sorted((project_dir / "sources").glob("*.md")):
        try:
            body = path.read_text(encoding="utf-8", errors="strict")
        except OSError:
            continue
        lowered = body.lower()
        score = 20 if query.lower() in lowered else 0
        score += sum(1 for term in terms if term in lowered)
        if score:
            ranked.append((str(path.relative_to(project_dir)), score))
    ranked.sort(key=lambda item: (-item[1], item[0]))
    return [Candidate(path, rank, str(score)) for rank, (path, score) in enumerate(ranked[:20], 1)]


def frontmatter_fields(path: Path) -> dict[str, Any]:
    """Read only the small scalar/list subset emitted by this fixture."""
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}
    fields: dict[str, Any] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        try:
            if value.startswith(("[", "{", '"')):
                fields[key] = json.loads(value)
            elif value in {"true", "false"}:
                fields[key] = value == "true"
            else:
                fields[key] = value
        except json.JSONDecodeError:
            fields[key] = value.strip('"')
    return fields


def as_refs(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    if isinstance(value, str) and value:
        return [value]
    return []


def canonical_state(project_dir: Path, candidate: Candidate, as_of: str | None) -> str:
    path = project_dir / candidate.path
    if not path.is_file():
        return candidate.state or "unknown"
    retraction = project_dir / "okf" / "retractions" / f"{Path(candidate.path).stem}.md"
    if retraction.is_file():
        return "retracted"
    fields = frontmatter_fields(path)
    if as_of:
        valid_from = str(fields.get("brain_valid_from", ""))
        valid_to = str(fields.get("brain_valid_to", ""))
        if valid_from and as_of < valid_from:
            return "not-yet-valid"
        if valid_to and as_of >= valid_to:
            return "expired"
    if as_refs(fields.get("brain_conflicts")):
        return "unresolved"
    review_state = str(fields.get("brain_review_state", ""))
    if review_state and review_state not in {"approved", "stable", "current"}:
        return review_state
    state = candidate.state or "current"
    if state in {"stable", "approved", "current", "active", "unknown-validity", "current-state"}:
        return "current"
    return state


def provenance_roots(project_dir: Path, path: str, seen: set[str] | None = None) -> set[str]:
    seen = set() if seen is None else seen
    if path in seen:
        return {path}
    seen.add(path)
    fields = frontmatter_fields(project_dir / path)
    parents = as_refs(fields.get("brain_derived_from"))
    parents.extend(as_refs(fields.get("brain_version_of")))
    if not parents:
        return {path}
    roots: set[str] = set()
    for parent in parents:
        if PATH_RE.fullmatch(parent):
            roots.update(provenance_roots(project_dir, parent, seen))
        else:
            roots.add(parent)
    return roots or {path}


def parse_search(stdout: str) -> list[Candidate]:
    rows = list(csv.reader(stdout.splitlines(), delimiter="\t"))
    if not rows:
        return []
    header = rows[0]
    if not header or header[0] != "path":
        raise EvaluationError("search output does not have the expected path header")
    candidates: list[Candidate] = []
    state_index = header.index("state") if "state" in header else -1
    title_index = header.index("title") if "title" in header else -1
    evidence_index = header.index("evidence_group") if "evidence_group" in header else -1
    provenance_index = header.index("provenance_state") if "provenance_state" in header else -1
    for rank, row in enumerate(rows[1:21], 1):
        if not row or not row[0]:
            continue
        if row[0] in NON_MEMORY_PATHS:
            continue
        candidates.append(
            Candidate(
                row[0],
                rank,
                row[1] if len(row) > 1 else "",
                row[state_index] if state_index >= 0 and len(row) > state_index else "",
                row[title_index] if title_index >= 0 and len(row) > title_index else "",
                row[evidence_index] if evidence_index >= 0 and len(row) > evidence_index else "",
                row[provenance_index] if provenance_index >= 0 and len(row) > provenance_index else "",
            )
        )
    return candidates


def read_evidence(project_dir: Path, candidates: list[Candidate]) -> tuple[list[dict[str, str]], int]:
    evidence: list[dict[str, str]] = []
    total = 0
    for candidate in candidates:
        path = project_dir / candidate.path
        try:
            path.resolve().relative_to(project_dir.resolve())
            body = path.read_text(encoding="utf-8", errors="strict")
        except (OSError, ValueError):
            continue
        excerpt = body[:4000]
        remaining = MAX_EVIDENCE_BYTES - total
        if remaining <= 0:
            break
        excerpt = excerpt[:remaining]
        evidence.append({"path": candidate.path, "text": excerpt})
        total += len(excerpt.encode("utf-8"))
    return evidence, total


def parse_metadata(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    return parse_key_values(path.read_text(encoding="utf-8", errors="replace"))


def answer_request(
    answer_runner: Path | None,
    request_dir: Path,
    trace_id: str,
    run_id: str,
    family_id: str,
    horizon: int,
    repeat: int,
    mode: str,
    query: Query,
    evidence: list[dict[str, str]],
) -> tuple[str, int | None, str | None, str | None]:
    if answer_runner is None:
        return "unmeasured", None, None, None
    # Each invocation receives a fresh cwd containing only its request/result;
    # cases, expected paths, future markers and host truth stay outside it.
    trace_dir = request_dir / trace_id
    trace_dir.mkdir(parents=True, exist_ok=True)
    request_path = trace_dir / "request.json"
    result_path = trace_dir / "result.json"
    request = {
        "schema": "llm-brain.lifecycle-answer-request-v1",
        "run_id": run_id,
        "trace_id": trace_id,
        "family_id": family_id,
        "horizon": horizon,
        "repeat": repeat,
        "mode": mode,
        "question": query.text,
        "evidence": evidence,
    }
    request_path.write_text(json.dumps(request, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    env = {key: value for key, value in os.environ.items() if key not in {"LLM_BRAIN_ROOT", "LLM_BRAIN_PROJECT_ID", "LLM_BRAIN_PASSIVE"}}
    env.update({"LLM_BRAIN_LIFECYCLE_EVAL": "1", "PYTHONNOUSERSITE": "1"})
    try:
        result = command([str(answer_runner), str(request_path), str(result_path)], timeout=60, cwd=trace_dir, env=env)
    except EvaluationError as exc:
        return "error", None, str(exc), None
    if result.returncode != 0:
        return "error", None, (result.stderr or result.stdout).strip()[:500], None
    if not result_path.is_file() or result_path.stat().st_size > MAX_OUTPUT_BYTES:
        return "error", None, "answer runner did not produce a bounded result", None
    raw = result_path.read_text(encoding="utf-8", errors="replace").strip()
    outcome = "unknown"
    tokens: int | None = None
    answer_text: str | None = None
    if raw.startswith("{"):
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        if isinstance(payload, dict):
            outcome = str(payload.get("outcome", payload.get("status", "unknown"))).lower()
            token_value = payload.get("tokens", payload.get("token_count"))
            if isinstance(token_value, int) and token_value >= 0:
                tokens = token_value
            if isinstance(payload.get("answer"), str):
                answer_text = payload["answer"][:MAX_OUTPUT_BYTES]
    else:
        for line in raw.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            value = value.strip()
            if key.strip().lower() == "outcome":
                outcome = value.lower()
            elif key.strip().lower() in {"tokens", "token_count"} and value.isdigit():
                tokens = int(value)
            elif key.strip().lower() == "answer":
                answer_text = value[:MAX_OUTPUT_BYTES]
    if outcome not in {"pass", "fail", "partial", "unknown"}:
        outcome = "unknown"
    return outcome, tokens, None, answer_text


def host_score_answer(query: Query, record_texts: dict[str, str], answer_text: str | None) -> tuple[bool | None, str]:
    """Score answer text against host-held fixture truth, never runner status."""
    if answer_text is None or not answer_text.strip():
        return None, "unscored-no-answer"
    if query.expected_answer is not None:
        expected = " ".join(query.expected_answer.split())
        actual = " ".join(answer_text.split())
        return actual == expected, "host-exact-fixture-answer"
    lowered = answer_text.lower()
    if not query.expected_paths:
        abstention = re.search(r"\b(no evidence|insufficient|unknown|cannot determine|unable to determine|not enough)\b", lowered)
        return bool(abstention), "host-abstention-match"
    expected_texts = [record_texts[path].lower() for path in query.expected_paths if path in record_texts]
    return bool(expected_texts) and all(text in lowered for text in expected_texts), "host-reference-phrase-match"


def trace_row(
    *,
    run_id: str,
    family: Family,
    horizon: int,
    repeat: int,
    query: Query,
    mode: str,
    candidates: list[Candidate],
    project_dir: Path,
    source_expected: bool,
    source_paths: list[str],
    answer_runner: Path | None,
    answer_dir: Path,
    event_count: int,
    cli: Path,
    run_identity: str,
    runtime: RuntimeState,
    checkpoint_label: str,
) -> dict[str, Any]:
    trace_id = f"{family.family_id}-{horizon}-{query.query_id}-{checkpoint_label}-{mode}-{repeat}"
    evidence, context_bytes = read_evidence(project_dir, candidates)
    path_set = {candidate.path for candidate in candidates}
    scored_paths = query.historical_expected_paths if mode == "historical" and query.historical_expected_paths else query.expected_paths
    if mode == "raw-source":
        if source_expected and not source_paths:
            # A raw-source hit is not a gold hit unless the fixture identifies
            # the expected source event. Presence alone is deliberately not a
            # passing score.
            gold_hit = False
        else:
            expected = set(source_paths) if source_expected else set()
            gold_hit = expected.issubset(path_set) if expected else not path_set
    elif scored_paths:
        gold_hit = set(scored_paths).issubset(path_set)
    else:
        gold_hit = not candidates
    unresolved = sum(1 for candidate in candidates if candidate.state and candidate.state not in {"current", "unknown-validity", "approved", "stable"})
    answer_outcome, answer_tokens, answer_error, answer_text = answer_request(
        answer_runner,
        answer_dir,
        trace_id,
        run_id,
        family.family_id,
        horizon,
        repeat,
        mode,
        query,
        evidence,
    )
    for candidate in candidates:
        candidate.state = canonical_state(project_dir, candidate, query.as_of)
    unresolved = sum(1 for candidate in candidates if candidate.state not in {"current", "unknown-validity", "approved", "stable"})
    state_correct: bool | None = None
    if query.expected_states:
        candidate_by_path = {candidate.path: candidate for candidate in candidates}
        state_correct = all(
            path in candidate_by_path
            and candidate_by_path[path].state == expected
            for path, expected in query.expected_states.items()
        )
    unresolved_ok: bool | None = None
    if query.require_unresolved:
        unresolved_ok = any(candidate.state == "unresolved" for candidate in candidates)
    roots: set[str] = set()
    for candidate in candidates:
        roots.update(provenance_roots(project_dir, candidate.path))
    provenance_ok: bool | None = None
    if query.require_provenance or query.require_independent_sources is not None:
        provenance_ok = bool(roots) and (
            query.require_independent_sources is None or len(roots) >= query.require_independent_sources
        )
    stale_paths = set(query.forbidden_paths)
    stale_leakage = bool(path_set.intersection(stale_paths))
    future_leakage = bool(path_set.intersection(query.future_paths))
    visibility_leakage = bool(path_set.intersection(query.visibility_forbidden_paths))
    repair_ok: bool | None = None
    if query.require_repair:
        # A repair assertion must name the records actually repaired.  Do not
        # infer targets from arbitrary forbidden retrieval paths: those may be
        # unrelated negatives and would make poisoning results look stronger.
        repair_targets = set(query.poisoned_paths)
        matching_repairs = [
            item.get("action_performed")
            and item.get("authority_preserved")
            and item.get("unrelated_preserved")
            and item.get("source_custody_preserved")
            and (not repair_targets or item.get("target") in repair_targets)
            for item in runtime.repair_results
        ]
        repair_ok = bool(matching_repairs) and all(matching_repairs)
    capsule_ok: bool | None = None
    if query.require_capsule_validation:
        capsule_ok = runtime.capsule_validated
    poisoning_safe: bool | None = None
    if query.poisoned_paths:
        poisoning_safe = repair_ok is True and not path_set.intersection(query.poisoned_paths)
    abstention_expected = not scored_paths
    abstention_correct = abstention_expected and not candidates
    correctness = gold_hit and not future_leakage and not visibility_leakage
    if mode != "historical" or not query.historical_relevant:
        correctness = correctness and not stale_leakage
    for assertion in (state_correct, unresolved_ok, provenance_ok, repair_ok, capsule_ok, poisoning_safe):
        if assertion is False:
            correctness = False
    answer_accuracy, answer_accuracy_reason = host_score_answer(query, runtime.record_texts, answer_text)
    return {
        "run_id": run_id,
        "run_identity": run_identity,
        "trace_id": trace_id,
        "family_id": family.family_id,
        "horizon": horizon,
        "repeat": repeat,
        "query_id": query.query_id,
        "mode": mode,
        "question": query.text,
        "candidate_paths": [candidate.path for candidate in candidates],
        "candidate_ranks": [candidate.rank for candidate in candidates],
        "gold_hit": gold_hit,
        "correctness": correctness,
        "state_correct": state_correct,
        "abstention_expected": abstention_expected,
        "abstention_correct": abstention_correct,
        "stale_leakage": stale_leakage,
        "future_leakage": future_leakage,
        "visibility_leakage": visibility_leakage,
        "root_count": len(roots),
        "provenance_ok": provenance_ok,
        "unresolved_ok": unresolved_ok,
        "repair_ok": repair_ok,
        "capsule_validation_ok": capsule_ok,
        "poisoning_safe": poisoning_safe,
        "source_gold_paths": source_paths,
        "source_gold_missing": bool(mode == "raw-source" and source_expected and not source_paths),
        "source_expected": source_expected,
        "unresolved_count": unresolved,
        "context_bytes": context_bytes,
        "token_estimate": (context_bytes + 3) // 4,
        "provider_calls": 1 if answer_runner else 0,
        "memory_write_cost": None,
        "event_count": event_count,
        "checkpoint_kind": checkpoint_label,
        "horizon_endpoint": checkpoint_label.startswith("horizon-"),
        "checkpoint_evaluated": event_count > 0,
        "answer_outcome": answer_outcome,
        "answer_tokens": answer_tokens,
        "answer_accuracy_measured": answer_runner is not None,
        "answer_text": answer_text,
        "answer_accuracy": answer_accuracy,
        "answer_accuracy_reason": answer_accuracy_reason,
        "answer_error": answer_error,
    }


def evaluate_query(
    cli: Path,
    vault: Path,
    project_dir: Path,
    family: Family,
    horizon: int,
    repeat: int,
    query: Query,
    mode: str,
    run_id: str,
    answer_runner: Path | None,
    answer_dir: Path,
    event_count: int,
    run_identity: str,
    runtime: RuntimeState,
    checkpoint_label: str,
) -> dict[str, Any]:
    started = time.monotonic()
    metadata_path = project_dir / "evaluations" / f".metadata-{family.family_id}-{horizon}-{query.query_id}-{mode}-{repeat}"
    candidates: list[Candidate]
    if mode == "none":
        candidates = []
    elif mode == "raw-source":
        candidates = source_candidates(project_dir, query.text)
    else:
        intent = MODE_INTENTS[mode]
        args = ["search", family.family_id, query.text, "--limit", "20", "--strategy", "lexical", "--intent", intent, "--explain", "--metadata-file", str(metadata_path)]
        if query.as_of:
            args.extend(["--as-of", query.as_of])
        if query.principal:
            args.extend(["--principal", query.principal])
        result = run_cli(cli, vault, args)
        candidates = parse_search(result.stdout)
    row = trace_row(
        run_id=run_id,
        family=family,
        horizon=horizon,
        repeat=repeat,
        query=query,
        mode=mode,
        candidates=candidates,
        project_dir=project_dir,
        source_expected=query.source_expected,
        source_paths=[runtime.capture_paths[event_id] for event_id in query.source_event_ids if event_id in runtime.capture_paths],
        answer_runner=answer_runner,
        answer_dir=answer_dir,
        event_count=event_count,
        cli=cli,
        run_identity=run_identity,
        runtime=runtime,
        checkpoint_label=checkpoint_label,
    )
    metadata = parse_metadata(metadata_path)
    row["retrieval_degraded"] = metadata.get("degraded", "false") == "true"
    row["retrieval_mode"] = metadata.get("retrieval_mode", mode)
    row["memory_write_cost"] = runtime.seed_write_cost + runtime.write_cost
    row["memory_write_bytes"] = runtime.seed_write_bytes + runtime.write_bytes
    row["operation_counts"] = dict(runtime.operation_counts)
    row["operation_writes"] = dict(runtime.operation_writes)
    row["operation_write_bytes"] = dict(runtime.operation_write_bytes)
    row["operation_elapsed_ms"] = {key: round(value, 3) for key, value in runtime.operation_elapsed_ms.items()}
    row["elapsed_ms"] = round((time.monotonic() - started) * 1000, 3)
    try:
        metadata_path.unlink()
    except OSError:
        pass
    return row


def materialise_events(family: Family, horizon: int, seed: int = 0) -> list[dict[str, Any]]:
    if len(family.events) > horizon:
        raise EvaluationError(f"{family.family_id}: explicit events exceed horizon {horizon}")
    events = [dict(event) for event in family.events]
    filler_prefix = f"Synthetic filler {digest_bytes(f'{seed}:{family.family_id}'.encode())[:12]}; no fixture answer."
    for index in range(len(events), horizon):
        events.append({"operation": "capture", "id": f"filler-{index:03d}", "text": f"{filler_prefix} sequence {index}."})
    return events


def run_scenario(
    cli: Path,
    repo_root: Path,
    family: Family,
    horizon: int,
    repeats: int,
    run_id: str,
    run_identity: str,
    answer_runner: Path | None,
    output_dir: Path,
    seed: int = 0,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix=f"llm-brain-lifecycle-{family.family_id}-{horizon}-") as temp:
        temp_root = Path(temp)
        vault = temp_root / "vault"
        project_id = family.family_id
        run_cli(cli, vault, ["project", "ensure", str(repo_root), "--id", project_id])
        project_dir = vault / "projects" / project_id
        truth_records = family.ground_truth.get("records", [])
        record_ids: dict[str, str] = {}
        # Ground truth is materialised before any source/conversation text.
        seed_before = file_snapshot(temp_root)
        for raw_record in truth_records:
            record = normalise_record(raw_record, family.family_id)
            record_ids[record["id"]] = record["path"]
            write_canonical(project_dir, record, project_id)
        capture_dir = temp_root / "captures"
        capture_dir.mkdir(parents=True, exist_ok=True)
        runtime = RuntimeState()
        runtime.record_texts = {
            record["path"]: record["text"]
            for record in (normalise_record(raw, family.family_id) for raw in truth_records)
        }
        seed_after = file_snapshot(temp_root)
        runtime.seed_write_cost, runtime.seed_write_bytes = snapshot_delta(seed_before, seed_after)
        events = materialise_events(family, horizon, seed)
        query_by_id = {query.query_id: query for query in family.queries}
        for index, event in enumerate(events):
            before = file_snapshot(temp_root)
            started = time.monotonic()
            apply_event(cli, vault, repo_root, project_id, project_dir, family, event, index, capture_dir, runtime, record_ids)
            after = file_snapshot(temp_root)
            writes, write_bytes = snapshot_delta(before, after)
            operation = event["operation"]
            runtime.operation_writes[operation] += writes
            runtime.operation_write_bytes[operation] += write_bytes
            runtime.write_cost += writes
            runtime.write_bytes += write_bytes
            runtime.operation_elapsed_ms[operation] += (time.monotonic() - started) * 1000
            if operation == "retrieval":
                query_id = safe_id(event.get("query_id"), f"{family.family_id} retrieval query id")
                query = query_by_id.get(query_id)
                if query is None:
                    raise EvaluationError(f"{family.family_id}: retrieval references unknown query {query_id}")
                runtime.retrieval_checkpoints.append({"query_id": query_id, "event_index": index, "event_count": index + 1, "status": "evaluated"})
                answer_dir = output_dir / "answer-requests" / f"{family.family_id}-{horizon}"
                for repeat in range(repeats):
                    for mode in MODES:
                        rows.append(
                            evaluate_query(
                                cli,
                                vault,
                                project_dir,
                                family,
                                horizon,
                                repeat,
                                query,
                                mode,
                                run_id,
                                answer_runner,
                                answer_dir,
                                index + 1,
                                run_identity,
                                runtime,
                                f"event-{index + 1}",
                            )
                        )
        before = file_snapshot(temp_root)
        flush_captures(cli, vault, repo_root, project_id, runtime)
        build_index(cli, vault, project_id)
        after = file_snapshot(temp_root)
        writes, write_bytes = snapshot_delta(before, after)
        runtime.write_cost += writes
        runtime.write_bytes += write_bytes
        answer_dir = output_dir / "answer-requests" / f"{family.family_id}-{horizon}"
        # Always score the horizon endpoint as well as explicit retrieval
        # markers. This makes 20/200-event horizons real checkpoints rather
        # than labels attached to an earlier state.
        for query in family.queries:
            for repeat in range(repeats):
                for mode in MODES:
                    rows.append(
                        evaluate_query(
                            cli,
                            vault,
                            project_dir,
                            family,
                            horizon,
                            repeat,
                            query,
                            mode,
                            run_id,
                            answer_runner,
                            answer_dir,
                            len(events),
                            run_identity,
                            runtime,
                            f"horizon-{horizon}",
                        )
                    )
    return rows


def summary(rows: list[dict[str, Any]], repeats: int) -> dict[str, Any]:
    def rate(items: list[dict[str, Any]], key: str) -> float | str:
        values = [row[key] for row in items if isinstance(row.get(key), bool)]
        return (sum(1 for value in values if value) / len(values)) if values else "unmeasured"

    by_mode: dict[str, dict[str, Any]] = {}
    for mode in MODES:
        mode_rows = [row for row in rows if row["mode"] == mode]
        groups: dict[tuple[str, int, str, str, str], list[dict[str, Any]]] = {}
        for row in mode_rows:
            groups.setdefault((row["family_id"], row["horizon"], row["query_id"], row.get("checkpoint_kind", "final"), str(row.get("event_count", "final"))), []).append(row)
        repeat_consistency = 0
        model_repeat_groups = 0
        model_repeat_pass = 0
        for group in groups.values():
            if len(group) != repeats:
                continue
            signatures = {tuple(row["candidate_paths"]) for row in group}
            if len(signatures) == 1:
                repeat_consistency += 1
            accuracies = [row.get("answer_accuracy") for row in group]
            if all(isinstance(value, bool) for value in accuracies):
                model_repeat_groups += 1
                model_repeat_pass += int(all(accuracies))
        answer_counts: dict[str, int] = {}
        for row in mode_rows:
            answer_counts[row["answer_outcome"]] = answer_counts.get(row["answer_outcome"], 0) + 1
        by_mode[mode] = {
            "traces": len(mode_rows),
            "gold_hits": sum(1 for row in mode_rows if row["gold_hit"]),
            "gold_hit_rate": (sum(1 for row in mode_rows if row["gold_hit"]) / len(mode_rows)) if mode_rows else 0.0,
            "correctness_rate": rate(mode_rows, "correctness"),
            "state_correct_rate": rate(mode_rows, "state_correct"),
            "abstention_correct_rate": rate(mode_rows, "abstention_correct"),
            "stale_leakage_rate": rate(mode_rows, "stale_leakage"),
            "future_leakage_rate": rate(mode_rows, "future_leakage"),
            "visibility_leakage_rate": rate(mode_rows, "visibility_leakage"),
            "provenance_rate": rate(mode_rows, "provenance_ok"),
            "capsule_validation_rate": rate(mode_rows, "capsule_validation_ok"),
            "repair_selective_rate": rate(mode_rows, "repair_ok"),
            "poisoning_safe_rate": rate(mode_rows, "poisoning_safe"),
            "retrieval_repeat_consistency": repeat_consistency / len(groups) if groups else 0.0,
            "model_pass_at_repeats": (model_repeat_pass / model_repeat_groups) if model_repeat_groups else "unmeasured",
            "groups": len(groups),
            "unresolved_results": sum(row["unresolved_count"] for row in mode_rows),
            "average_context_bytes": (sum(row["context_bytes"] for row in mode_rows) / len(mode_rows)) if mode_rows else 0.0,
            "average_elapsed_ms": (sum(row["elapsed_ms"] for row in mode_rows) / len(mode_rows)) if mode_rows else 0.0,
            "average_token_estimate": (sum(row["token_estimate"] for row in mode_rows) / len(mode_rows)) if mode_rows else 0.0,
            "max_memory_write_cost": max((row.get("memory_write_cost") or 0 for row in mode_rows), default=0),
            "checkpoint_evaluated": bool(mode_rows) and all(row.get("event_count", 0) > 0 for row in mode_rows),
            "answer_outcomes": answer_counts,
            "model_accuracy": rate(mode_rows, "answer_accuracy"),
        }
    scenario_operation_counts: dict[tuple[str, int], dict[str, int]] = {}
    scenario_operation_writes: dict[tuple[str, int], dict[str, int]] = {}
    scenario_operation_write_bytes: dict[tuple[str, int], dict[str, int]] = {}
    scenario_operation_elapsed: dict[tuple[str, int], dict[str, float]] = {}
    scenario_write_costs: dict[tuple[str, int], int] = {}
    for row in rows:
        key = (row["family_id"], row["horizon"])
        counts = scenario_operation_counts.setdefault(key, {})
        writes = scenario_operation_writes.setdefault(key, {})
        write_bytes = scenario_operation_write_bytes.setdefault(key, {})
        elapsed = scenario_operation_elapsed.setdefault(key, {})
        for operation, count in row.get("operation_counts", {}).items():
            counts[operation] = max(counts.get(operation, 0), int(count))
        for operation, count in row.get("operation_writes", {}).items():
            writes[operation] = max(writes.get(operation, 0), int(count))
        for operation, count in row.get("operation_write_bytes", {}).items():
            write_bytes[operation] = max(write_bytes.get(operation, 0), int(count))
        for operation, duration in row.get("operation_elapsed_ms", {}).items():
            elapsed[operation] = max(elapsed.get(operation, 0.0), float(duration))
        scenario_write_costs[key] = max(scenario_write_costs.get(key, 0), row.get("memory_write_cost") or 0)
    operation_counts: dict[str, int] = {}
    operation_writes: dict[str, int] = {}
    operation_write_bytes: dict[str, int] = {}
    operation_elapsed_ms: dict[str, float] = {}
    for counts in scenario_operation_counts.values():
        for operation, count in counts.items():
            operation_counts[operation] = operation_counts.get(operation, 0) + count
    for writes in scenario_operation_writes.values():
        for operation, count in writes.items():
            operation_writes[operation] = operation_writes.get(operation, 0) + count
    for write_bytes in scenario_operation_write_bytes.values():
        for operation, count in write_bytes.items():
            operation_write_bytes[operation] = operation_write_bytes.get(operation, 0) + count
    for elapsed in scenario_operation_elapsed.values():
        for operation, duration in elapsed.items():
            operation_elapsed_ms[operation] = round(operation_elapsed_ms.get(operation, 0.0) + duration, 3)
    # Disposable v0.7 labels.  These are deliberately descriptive rows rather
    # than new lifecycle primitives; external KV/session state is out of scope.
    experiments = [
        {"label": "indirect_association", "benchmark": "Keep It InMind", "status": "unmeasured", "metric": "unmeasured", "scope": "external_kv_session_state"},
        {"label": "eviction_restore_counterfactual", "benchmark": "What Eviction Destroys", "status": "unmeasured", "metric": "unmeasured", "scope": "external_kv_session_state"},
        {"label": "execution_state_forgetting", "benchmark": "Forgetting Without Restarting", "status": "unmeasured", "metric": "unmeasured", "scope": "external_kv_session_state"},
    ]
    repair_rows = [row for row in rows if row.get("repair_ok") is not None]
    repair_experiment = {
        "raw_source_vs_derived_only": "measured_by_repair_isolation",
        "source_hashes_preserved": bool(repair_rows) and all(row.get("repair_ok") for row in repair_rows),
        "unrelated_records_preserved": bool(repair_rows) and all(row.get("poisoning_safe") for row in repair_rows),
        "rows": len(repair_rows),
    }
    portability = {"status": "unsupported", "metric": "unmeasured", "reason": "external KV and session-state portability is outside this repository-only harness", "matrix": []}
    return {
        "repeats": repeats,
        "repetition_semantics": "deterministic retrieval repetition; not model pass^5",
        "modes": by_mode,
        "actual_write_cost": sum(scenario_write_costs.values()),
        "max_scenario_write_cost": max(scenario_write_costs.values(), default=0),
        "operation_counts": operation_counts,
        "operation_writes": operation_writes,
        "operation_write_bytes": operation_write_bytes,
        "operation_elapsed_ms": operation_elapsed_ms,
        "checkpoint_rows": sum(1 for row in rows if row.get("checkpoint_evaluated")),
        "horizon_endpoint_rows": sum(1 for row in rows if row.get("horizon_endpoint")),
        "model_accuracy_note": "host-scored answer text only; runner outcome is not accuracy",
        "experiments": experiments,
        "repair_experiment": repair_experiment,
        "portability": portability,
    }


def read_portability_matrix(path: Path) -> list[dict[str, str]]:
    if not path.is_file() or path.is_symlink():
        raise EvaluationError(f"portability matrix is not a regular file: {path}")
    with path.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    required = {"writer_identity", "writer_cli", "reader_identity", "reader_cli", "direction"}
    if not rows or set(rows[0]) != required:
        raise EvaluationError("portability matrix must contain exactly the required TSV columns")
    for row in rows:
        for key in required:
            row[key] = single_line(row.get(key, ""), f"portability {key}", 512)
        if row["direction"] not in {"forward", "reverse", "none"}:
            raise EvaluationError("portability direction must be none, forward or reverse")
    return rows


def portability_results(matrix: list[dict[str, str]], families: list[Family], repo_root: Path, output_dir: Path, seed: int) -> list[dict[str, Any]]:
    results = []
    for item in matrix:
        writer, reader = Path(item["writer_cli"]).expanduser().resolve(), Path(item["reader_cli"]).expanduser().resolve()
        base = {"writer_identity": item["writer_identity"], "reader_identity": item["reader_identity"], "direction": item["direction"], "writer_cli_sha256": "unmeasured", "reader_cli_sha256": "unmeasured"}
        if not (writer.is_file() and os.access(writer, os.X_OK) and reader.is_file() and os.access(reader, os.X_OK)):
            results.append(dict(base, status="unmeasured", metric="unmeasured", reason="local CLI missing or not executable")); continue
        base.update(writer_cli_sha256=digest_file(writer), reader_cli_sha256=digest_file(reader))
        with tempfile.TemporaryDirectory(prefix="llm-brain-portability-") as temp:
            a = run_scenario(writer, repo_root, families[0], families[0].horizons[0], 1, "portability-writer", "writer", None, Path(temp), seed)
            b = run_scenario(reader, repo_root, families[0], families[0].horizons[0], 1, "portability-reader", "reader", None, Path(temp), seed)
        amap = {(r["mode"], r["query_id"]): set(r["candidate_paths"]) for r in a}
        bmap = {(r["mode"], r["query_id"]): set(r["candidate_paths"]) for r in b}
        agreements = sum(amap.get(k) == v for k, v in amap.items() if k in bmap)
        total = sum(k in bmap for k in amap)
        results.append(dict(base, status="measured", agreement_rate=(agreements / total if total else 0.0), candidate_set_deltas=sum(amap.get(k, set()) != bmap.get(k, set()) for k in set(amap) | set(bmap))))
    return results


def write_trace(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def write_tsv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = [
        "run_id",
        "repository_commit",
        "provider",
        "provider_version",
        "provider_commit",
        "model",
        "dimension",
        "dimensions",
        "build_status",
        "warm_cold",
        "availability",
        "degraded_path",
        "budget_tokens",
        "configuration",
        "family_id",
        "horizon",
        "repeat",
        "query_id",
        "mode",
        "candidate_paths",
        "gold_hit",
        "correctness",
        "state_correct",
        "abstention_correct",
        "stale_leakage",
        "future_leakage",
        "visibility_leakage",
        "root_count",
        "provenance_ok",
        "repair_ok",
        "capsule_validation_ok",
        "poisoning_safe",
        "unresolved_count",
        "context_bytes",
        "token_estimate",
        "provider_calls",
        "memory_write_cost",
        "memory_write_bytes",
        "elapsed_ms",
        "answer_outcome",
        "answer_accuracy",
        "retrieval_degraded",
    ]
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            output = dict(row)
            output["candidate_paths"] = ",".join(row["candidate_paths"])
            output["configuration"] = json.dumps(row.get("configuration", {}), sort_keys=True, separators=(",", ":"))
            writer.writerow(output)


def write_report(
    path: Path,
    run_id: str,
    identity: dict[str, Any],
    families: list[Family],
    rows: list[dict[str, Any]],
    metrics: dict[str, Any],
    answer_runner: Path | None,
) -> None:
    lines = [
        f"# LLM-Brain lifecycle evaluation `{run_id}`",
        "",
        "This is a derived, ground-truth-first evaluation. Each scenario ran in a disposable vault and the vault was removed after scoring.",
        "",
        f"- Scenario families: {len(families)}",
        f"- Horizons: {', '.join(str(value) for value in sorted({h for family in families for h in family.horizons}))} events",
        f"- Repeats: {identity['repeats']}",
        f"- Answer runner: {'configured' if answer_runner else 'absent; model accuracy unmeasured'}",
        f"- Runner isolation: {identity['answer_runner_policy']}",
        f"- Provider: `{identity['provider']}` ({identity['provider_version']}; commit `{identity['provider_commit']}`)",
        f"- Model and dimensions: `{identity['model']}` / `{identity['dimensions']}`",
        f"- Build status: `{identity['build_status']}`",
        f"- Warm/cold state: `{identity['warm_cold']}`",
        f"- Availability: `{identity['availability']}`; degraded path: `{identity['degraded_path']}`",
        f"- Portability: writer `{identity['writer_identity']}` → reader `{identity['reader_identity']}`; direction `{identity['migration_direction']}`",
        f"- Portability hashes: source `{identity['source_hash']}`, index `{identity['index_hash']}`, runner `{identity['runner_hash']}`",
        f"- Evaluation budget: `{identity['budget_tokens']}` tokens",
        f"- Run identity: `{identity['identity_hash']}`",
        "",
        "Expected paths remain fixture-only scoring data and are never included in answer-runner requests.",
        "",
        "## Mode metrics",
        "",
        "| Mode | Traces | Gold hits | Hit rate | Correctness | Repeat consistency | Unresolved | Model accuracy |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for mode in MODES:
        metric = metrics["modes"][mode]
        model_accuracy = metric["model_accuracy"]
        lines.append(
            f"| {mode} | {metric['traces']} | {metric['gold_hits']} | {metric['gold_hit_rate']:.3f} | {metric['correctness_rate']} | {metric['retrieval_repeat_consistency']:.3f} | {metric['unresolved_results']} | {model_accuracy} |"
        )
    lines.extend(
        [
            "",
            "## Artefacts",
            "",
            "- `run.json` binds case, CLI, script, answer-runner and seed hashes.",
            "- `trace.jsonl` is the complete machine-readable trace; `trace.tsv` is its tabular view.",
            "- `summary.json` contains retrieval, unresolved-state, cost and repeat reliability metrics.",
            "- `summary.json` also contains disposable v0.7 experiment labels and raw-source repair preservation checks; external KV/session-state portability is explicitly unsupported.",
            "- `answer-requests/` contains only question/evidence requests when an answer runner is configured.",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run bounded ground-truth-first LLM-Brain lifecycle evaluations")
    parser.add_argument("--cases", required=True, help="versioned JSON case file")
    parser.add_argument("--output", required=True, help="new output directory; existing paths are rejected")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--answer-runner", help="executable receiving request.json and output.json paths")
    parser.add_argument("--provider", default="llm-brain")
    parser.add_argument("--provider-version")
    parser.add_argument("--provider-commit")
    parser.add_argument("--model", default="unconfigured")
    parser.add_argument("--dimension", "--dimensions", dest="dimensions", default="unconfigured")
    parser.add_argument("--build-status", choices=("stable", "main", "build", "local", "unknown"), default="local")
    parser.add_argument("--warm-cold", choices=("warm", "cold", "unknown"), default="unknown")
    parser.add_argument("--availability", choices=("available", "unavailable", "degraded"), default="available")
    parser.add_argument("--degraded-path", default="none")
    parser.add_argument("--writer-identity", default="llm-brain-evaluator")
    parser.add_argument("--reader-identity", default="llm-brain-evaluator")
    parser.add_argument("--migration-direction", choices=("none", "forward", "reverse"), default="none")
    parser.add_argument("--portability-matrix", help="optional TSV of local writer/reader CLI pairs")
    args = parser.parse_args(argv)
    if args.seed < 0 or args.repeats < 1 or args.repeats > 50:
        parser.error("--seed must be non-negative and --repeats must be between 1 and 50")
    repo_root = Path(__file__).resolve().parents[1]
    cli = repo_root / "bin" / "llm-brain"
    if not cli.is_file() or not os.access(cli, os.X_OK):
        parser.error(f"reference CLI is unavailable: {cli}")
    cases_path = Path(args.cases).expanduser().resolve()
    output_dir = Path(args.output).expanduser().resolve()
    answer_runner = Path(args.answer_runner).expanduser().resolve() if args.answer_runner else None
    if answer_runner and (not answer_runner.is_file() or answer_runner.is_symlink() or not os.access(answer_runner, os.X_OK)):
        parser.error(f"answer runner is not an executable regular file: {answer_runner}")
    try:
        provider = single_line(args.provider, "--provider", 256)
        package_version = (repo_root / "VERSION").read_text(encoding="utf-8").strip() if (repo_root / "VERSION").is_file() else "unresolved"
        provider_version = single_line(args.provider_version or package_version, "--provider-version", 256)
        provider_commit = single_line(args.provider_commit or repository_revision(repo_root), "--provider-commit", 256)
        model = single_line(args.model, "--model", 256)
        dimensions = single_line(args.dimensions, "--dimensions", 128)
        degraded_path = single_line(args.degraded_path, "--degraded-path", 256)
        writer_identity = single_line(args.writer_identity, "--writer-identity", 256)
        reader_identity = single_line(args.reader_identity, "--reader-identity", 256)
        families, payload = parse_cases(read_json(cases_path))
        portability_matrix = read_portability_matrix(Path(args.portability_matrix).expanduser().resolve()) if args.portability_matrix else []
        script_hash = digest_file(Path(__file__))
        cli_hash = digest_file(cli)
        cases_hash = digest_file(cases_path)
        answer_hash = digest_file(answer_runner) if answer_runner else "none"
        repository_commit = repository_revision(repo_root)
        identity_material = {
            "format": FORMAT,
            "version": VERSION,
            "cases_sha256": cases_hash,
            "script_sha256": script_hash,
            "cli_sha256": cli_hash,
            "answer_runner_sha256": answer_hash,
            "answer_runner_policy": "trusted local executable; no OS sandbox",
            "source_sha256": script_hash,
            "executable_sha256": cli_hash,
            "repository_commit": repository_commit,
            "provider": provider,
            "provider_version": provider_version,
            "provider_commit": provider_commit,
            "model": model,
            "dimension": dimensions,
            "dimensions": dimensions,
            "build_status": args.build_status,
            "warm_cold": args.warm_cold,
            "availability": args.availability,
            "degraded_path": degraded_path,
            "writer_identity": writer_identity,
            "reader_identity": reader_identity,
            "migration_direction": args.migration_direction,
            # Explicitly named portability inputs; the evaluator never trusts
            # these as semantic compatibility proof.
            "source_hash": cases_hash,
            # The index is rebuilt inside each disposable scenario, so there
            # is no single pre-run index hash to claim here.
            "index_hash": "unmeasured_disposable_index",
            "runner_hash": answer_hash,
            "budget_tokens": EVALUATION_BUDGET_TOKENS,
            "configuration": {
                "seed": args.seed,
                "repeats": args.repeats,
                "budget_tokens": EVALUATION_BUDGET_TOKENS,
                "answer_runner_sha256": answer_hash,
            },
            "seed": args.seed,
            "repeats": args.repeats,
        }
        identity_hash = digest_bytes(json.dumps(identity_material, sort_keys=True).encode("utf-8"))
        run_id = f"lifecycle_{identity_hash[:20]}"
        identity = dict(identity_material, identity_hash=identity_hash, run_id=run_id)
        if output_dir.exists():
            existing = output_dir / "run.json"
            if existing.is_file():
                try:
                    old_identity = json.loads(existing.read_text(encoding="utf-8")).get("identity_hash")
                except (OSError, UnicodeError, json.JSONDecodeError):
                    old_identity = None
                if old_identity and old_identity != identity_hash:
                    raise EvaluationError("existing output identity mismatch; refusing to overwrite")
            raise EvaluationError(f"output directory already exists; refusing to overwrite: {output_dir}")
        output_dir.parent.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir()
        write_json(output_dir / "run.json", identity)
        rows: list[dict[str, Any]] = []
        for family in families:
            for horizon in family.horizons:
                rows.extend(run_scenario(cli, repo_root, family, horizon, args.repeats, run_id, identity_hash, answer_runner, output_dir, args.seed))
        trace_metadata = {
            "repository_commit": repository_commit,
            "provider": provider,
            "provider_version": provider_version,
            "provider_commit": provider_commit,
            "model": model,
            "dimension": dimensions,
            "dimensions": dimensions,
            "build_status": args.build_status,
            "warm_cold": args.warm_cold,
            "availability": args.availability,
            "degraded_path": degraded_path,
            "writer_identity": writer_identity,
            "reader_identity": reader_identity,
            "migration_direction": args.migration_direction,
            "source_hash": cases_hash,
            "index_hash": "unmeasured_disposable_index",
            "runner_hash": answer_hash,
            "budget_tokens": EVALUATION_BUDGET_TOKENS,
            "configuration": {
                "seed": args.seed,
                "repeats": args.repeats,
                "budget_tokens": EVALUATION_BUDGET_TOKENS,
            },
        }
        for row in rows:
            row.update(trace_metadata)
        metrics = summary(rows, args.repeats)
        if portability_matrix:
            matrix_results = portability_results(portability_matrix, families, repo_root, output_dir, args.seed)
            metrics["portability"] = {
                "status": "measured" if all(row["status"] == "measured" for row in matrix_results) else "unmeasured",
                "metric": "local_cli_candidate_agreement",
                "scope": "local_cli_only",
                "matrix": matrix_results,
            }
        write_trace(output_dir / "trace.jsonl", rows)
        write_tsv(output_dir / "trace.tsv", rows)
        write_json(output_dir / "summary.json", {"run_id": run_id, "evaluation_metadata": trace_metadata, **metrics})
        write_report(output_dir / "report.md", run_id, identity, families, rows, metrics, answer_runner)
        print(f"lifecycle_eval=ok run_id={run_id} output={output_dir} traces={len(rows)} families={len(families)}")
        return 0
    except (EvaluationError, OSError, ValueError) as exc:
        print(f"lifecycle_eval=failed reason={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
