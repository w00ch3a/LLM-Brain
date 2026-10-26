#!/usr/bin/env python3
"""Build a private, offline HTML projection from one explicit LLM-Brain project.

This is a one-shot snapshot exporter, not a web server or authentication
provider. The caller supplies the existing vault root, project ID, and
principal filter explicitly. The principal is a visibility filter, not proof
of caller identity; the output file is created owner-only and must stay local.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


VISUALIZER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(VISUALIZER))

from build_demo import render_html  # noqa: E402
from export_graph import ExportError, _frontmatter, _refs, build_export  # noqa: E402
from snapshot_producer import build_snapshot  # noqa: E402


class LocalSnapshotError(RuntimeError):
    """Safe local snapshot/export error."""


PROJECT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def _inside(candidate: Path, parent: Path) -> bool:
    try:
        candidate.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_principal(principal: str) -> None:
    if (
        not isinstance(principal, str)
        or not principal
        or principal != principal.strip()
        or any(ord(character) < 32 for character in principal)
    ):
        raise LocalSnapshotError("an exact principal filter is required")


def _validate_output(output: Path, vault_root: Path) -> Path:
    if not output.is_absolute():
        raise LocalSnapshotError("output path must be absolute")
    if output.suffix.lower() != ".html" or output.name in {".", ".."}:
        raise LocalSnapshotError("output must be a new .html file")
    try:
        parent = output.parent.resolve(strict=True)
    except OSError as exc:
        raise LocalSnapshotError("output directory is unavailable") from exc
    target = parent / output.name
    if target.exists() or target.is_symlink():
        raise LocalSnapshotError("output must be a new file")
    if _inside(target, vault_root):
        raise LocalSnapshotError("output must be outside the vault")
    return target


def _assert_no_writer(vault_root: Path, project_id: str) -> None:
    locks = vault_root / ".locks"
    if locks.is_symlink():
        raise LocalSnapshotError("vault lock state unavailable")
    project_lock = locks / f"project-{project_id}.lock"
    if project_lock.is_symlink() or project_lock.exists():
        raise LocalSnapshotError("project writer is active; retry after it finishes")

    base = vault_root.name
    parent = vault_root.parent
    for transition in (parent / f".{base}.upgrade.lock", parent / f".{base}.migration.lock"):
        if transition.is_symlink() or transition.exists():
            raise LocalSnapshotError("vault transition is active; retry after it finishes")


def _write_owner_only_new_file(path: Path, contents: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        raise LocalSnapshotError("could not create private output file") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        if stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise LocalSnapshotError("output permissions are not owner-only")
    except Exception:
        path.unlink(missing_ok=True)
        raise


LINEAGE_LABEL_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}(?::[A-Za-z0-9._/@+-]{1,160})?$")


def attach_lineage(payload: dict, project_root: Path) -> None:
    """Add active label-ledger labels to visible nodes (0.9 label lineage).

    Only labels on records already in the principal-filtered node set are
    attached, and only label edges whose both endpoints are visible.  Reasons
    and actors are never exported.  A missing, symlinked or malformed ledger
    is ignored (the view simply has no labels).
    """
    ledger = project_root / "lineage" / "labels.tsv"
    if ledger.is_symlink() or not ledger.is_file():
        return
    visible = {node["id"] for node in payload.get("nodes", [])}
    active: dict[str, dict[str, str]] = {}
    try:
        lines = ledger.read_text(encoding="utf-8").splitlines()[1:]
    except (OSError, UnicodeDecodeError):
        return
    for line in lines:
        fields = line.split("\t")
        if len(fields) != 9:
            continue
        _, _, action, ref, label, target = fields[:6]
        if ref not in visible or not LINEAGE_LABEL_RE.fullmatch(label):
            continue
        bucket = active.setdefault(ref, {})
        if action == "label":
            bucket[label] = target if target in visible else ""
        elif action == "unlabel":
            bucket.pop(label, None)
    for node in payload.get("nodes", []):
        labels = active.get(node["id"])
        if labels:
            node["labels"] = sorted(labels)
    for ref, labels in sorted(active.items()):
        for label, target in sorted(labels.items()):
            if target:
                payload.setdefault("edges", []).append({"source": ref, "relation": "label:" + label.split(":", 1)[0], "target": target})


PENDING_SHOWN_CAP = 300
PENDING_SCAN_LIMIT = 20000
PENDING_HEAD_BYTES = 16384
PENDING_READ_WORKERS = 16
PENDING_STATES = {"proposed", "pending", "needs-review", "unreviewed"}
DAY_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})")


def _pending_visible(meta: dict, principal: str) -> bool:
    """Same principal/audience/sensitivity rules as canonical records, minus approval."""
    if meta.get("type") != "ReviewItem":
        return False
    kind = meta.get("brain_review_kind", "")
    state = meta.get("brain_review_state", "")
    if not isinstance(kind, str) or not isinstance(state, str):
        return False
    if kind.strip().lower() == "redaction" or state.strip().lower() not in PENDING_STATES:
        return False
    sensitivity = meta.get("brain_sensitivity", meta.get("sensitivity", "internal"))
    if sensitivity is None:
        sensitivity = "internal"
    if sensitivity != "internal":
        return False
    scoped = _refs(meta.get("brain_principal"))
    audience = _refs(meta.get("brain_audience"))
    if scoped is None or audience is None:
        return False
    identities = scoped + audience
    return not identities or principal in identities


def _read_frontmatter_head(path: Path) -> dict | None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        raw = os.read(fd, PENDING_HEAD_BYTES)
    except OSError:
        return None
    finally:
        os.close(fd)
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return None
    end = next((i for i, line in enumerate(lines[1:], 1) if line.strip() == "---"), None)
    if end is None:
        return None
    try:
        meta, _ = _frontmatter("".join(lines[: end + 1]).encode("utf-8") + b"\n")
    except (ExportError, ValueError):
        return None
    return meta if isinstance(meta, dict) else None


def attach_pending(payload: dict, project_root: Path, principal: str, cap: int = PENDING_SHOWN_CAP) -> None:
    """Add unreviewed review-queue items as clearly marked, principal-filtered nodes.

    Only frontmatter is read; bodies and source refs are never exported.  The
    newest ``cap`` items are shown individually; the rest are summarised into
    per-day cluster nodes with exact counts, and totals go into
    ``meta.pending`` so nothing is dropped silently.  Every shown item is
    linked to its capture-day node (derived relation ``captured_on``).
    """
    review = project_root / "review"
    summary = {"total": 0, "shown": 0, "clustered": 0, "clusters": 0, "excluded": 0, "cap": cap}
    payload.setdefault("meta", {})["pending"] = summary
    if review.is_symlink() or not review.is_dir():
        return
    items = []
    try:
        entries = sorted(review.iterdir())
    except OSError:
        return
    candidates = [path for path in entries[:PENDING_SCAN_LIMIT] if path.suffix == ".md"]
    # Network vaults (CIFS/NFS) are latency-bound: read frontmatter heads in parallel.
    with ThreadPoolExecutor(max_workers=PENDING_READ_WORKERS) as pool:
        heads = list(pool.map(_read_frontmatter_head, candidates))
    for path, meta in zip(candidates, heads):
        if meta is None or meta.get("type") != "ReviewItem":
            continue
        if not _pending_visible(meta, principal):
            summary["excluded"] += 1
            continue
        stamp = meta.get("timestamp", "")
        stamp = stamp.isoformat() if hasattr(stamp, "isoformat") else str(stamp or "")
        title = meta.get("title")
        title = " ".join(str(title).split())[:120] if isinstance(title, (str, int, float)) and str(title).strip() else path.stem
        kind = meta.get("brain_review_kind")
        items.append({
            "id": "review/" + path.name,
            "title": title,
            "stamp": stamp,
            "day": (DAY_RE.match(stamp).group(1) if DAY_RE.match(stamp) else "undated"),
            "kind": kind if isinstance(kind, str) else "",
        })
    summary["truncated_scan"] = len(entries) > PENDING_SCAN_LIMIT
    summary["total"] = len(items)
    items.sort(key=lambda item: (item["stamp"], item["id"]), reverse=True)
    shown, rest = items[: max(0, cap)], items[max(0, cap):]
    nodes = payload.setdefault("nodes", [])
    edges = payload.setdefault("edges", [])
    days: dict[str, dict] = {}
    for item in items:
        days.setdefault(item["day"], {"shown": 0, "clustered": 0})
    for item in shown:
        days[item["day"]]["shown"] += 1
    for item in rest:
        days[item["day"]]["clustered"] += 1
    for day, bucket in sorted(days.items()):
        total = bucket["shown"] + bucket["clustered"]
        label = f"Unreviewed · {day} · {total} item{'s' if total != 1 else ''}"
        if bucket["clustered"]:
            label += f" ({bucket['clustered']} grouped)"
        nodes.append({
            "id": f"review-day/{day}",
            "title": label,
            "type": "UnreviewedBatch",
            "status": "unreviewed",
            "unreviewed": True,
            "trust": "unreviewed",
            "generated": day if day != "undated" else "",
            "provenance": "Review queue (pending)",
            "excerpt": f"{total} unreviewed review-queue items captured {day}; {bucket['shown']} shown individually, {bucket['clustered']} grouped here. Content is not exported until reviewed.",
            "count": total,
            "grouped": bucket["clustered"],
        })
    for item in shown:
        nodes.append({
            "id": item["id"],
            "title": item["title"],
            "type": "ReviewItem",
            "status": "unreviewed",
            "unreviewed": True,
            "trust": "unreviewed",
            "generated": item["stamp"],
            "provenance": "Review queue (pending" + (", " + item["kind"] if item["kind"] else "") + ")",
            "excerpt": "Unreviewed review-queue item. Body not exported until reviewed.",
        })
        edges.append({"source": item["id"], "relation": "captured_on", "target": f"review-day/{item['day']}"})
    ordered_days = sorted(d for d in days if d != "undated")
    for earlier, later in zip(ordered_days, ordered_days[1:]):
        edges.append({"source": f"review-day/{later}", "relation": "follows", "target": f"review-day/{earlier}"})
    summary.update(shown=len(shown), clustered=len(rest), clusters=len(days))


def _resolve_vault(vault_root_arg: Path) -> Path:
    if not vault_root_arg.is_absolute() or vault_root_arg.is_symlink():
        raise LocalSnapshotError("vault root must be an absolute, non-symlink directory")
    try:
        vault_root = vault_root_arg.resolve(strict=True)
    except OSError as exc:
        raise LocalSnapshotError("vault root is unavailable") from exc
    if not vault_root.is_dir():
        raise LocalSnapshotError("vault root is unavailable")
    return vault_root


def _resolve_project(vault_root: Path, project_id: str) -> Path:
    if not PROJECT_ID_RE.fullmatch(project_id) or project_id in {".", ".."}:
        raise LocalSnapshotError("invalid project ID")
    projects = vault_root / "projects"
    project_path = projects / project_id
    if projects.is_symlink() or project_path.is_symlink() or not project_path.is_dir():
        raise LocalSnapshotError("selected project is unavailable")
    try:
        projects_real = projects.resolve(strict=True)
        project_root = project_path.resolve(strict=True)
    except OSError as exc:
        raise LocalSnapshotError("selected project is unavailable") from exc
    if project_root.parent != projects_real:
        raise LocalSnapshotError("selected project is unavailable")
    return project_root


def _project_payload(vault_root: Path, project_root: Path, project_id: str, principal: str,
                     include_pending: bool, cap: int) -> dict:
    """Filtered payload for one project, built from a private hardened snapshot."""
    _assert_no_writer(vault_root, project_id)
    try:
        with tempfile.TemporaryDirectory(prefix="llm-brain-neural-expansion-") as private_temp:
            private_root = Path(private_temp)
            os.chmod(private_root, 0o700)
            package = private_root / "snapshot"
            build_snapshot(project_root, package)
            payload = build_export(package, principal)
            attach_lineage(payload, project_root)
            if include_pending:
                attach_pending(payload, project_root, principal, cap=cap)
    except (ExportError, OSError) as exc:
        raise LocalSnapshotError("consistent filtered snapshot unavailable") from exc
    _assert_no_writer(vault_root, project_id)
    return payload


def _render_and_write(payload: dict, output: Path) -> None:
    page = render_html(payload, "NEURAL EXPANSION · LOCAL SNAPSHOT · PRINCIPAL-FILTERED · READ ONLY")
    try:
        _write_owner_only_new_file(output, page)
    except OSError as exc:
        raise LocalSnapshotError("consistent filtered snapshot unavailable") from exc


def build_local_snapshot_html(
    vault_root_arg: Path,
    project_id: str,
    principal: str,
    output_arg: Path,
    include_pending: bool = True,
) -> Path:
    """Read one explicit project snapshot, filter it, and write owner-only HTML."""
    if not PROJECT_ID_RE.fullmatch(project_id) or project_id in {".", ".."}:
        raise LocalSnapshotError("invalid project ID")
    _validate_principal(principal)
    vault_root = _resolve_vault(vault_root_arg)
    project_root = _resolve_project(vault_root, project_id)
    output = _validate_output(output_arg, vault_root)
    payload = _project_payload(vault_root, project_root, project_id, principal, include_pending, PENDING_SHOWN_CAP)
    _render_and_write(payload, output)
    return output


ALL_PROJECTS_SHOWN_BUDGET = 600
ALL_PROJECTS_MIN_CAP = 20
ALL_PROJECTS_WORKERS = 4


def merge_project_payloads(results: list) -> dict:
    """Merge per-project payloads into one graph grouped by a node per project.

    ``results`` holds ``(project_id, payload_or_None, error_text)`` tuples.
    Node ids are suffixed with ``#<project>`` so equal paths in different
    projects stay distinct (the path prefix still drives the record layer).
    """
    nodes: list = []
    edges: list = []
    per_project: list = []
    totals = {"total": 0, "shown": 0, "clustered": 0, "clusters": 0, "excluded": 0}
    skipped = []
    for project_id, payload, error in results:
        if payload is None:
            skipped.append({"project_id": project_id, "reason": error or "unavailable"})
            continue
        suffix = "#" + project_id
        hub = "project/" + project_id
        pending = (payload.get("meta") or {}).get("pending") or {}
        reviewed = [node for node in payload.get("nodes", []) if not node.get("unreviewed")]
        unreviewed = [node for node in payload.get("nodes", []) if node.get("unreviewed")]
        nodes.append({
            "id": hub, "title": f"{project_id} · {len(reviewed)} reviewed · {int(pending.get('total') or 0)} unreviewed",
            "type": "Project", "status": "project", "trust": "grouping", "generated": "",
            "provenance": "Project registry", "project": project_id,
            "excerpt": f"{len(reviewed)} reviewed records and {int(pending.get('total') or 0)} unreviewed review-queue items visible to this principal.",
        })
        for node in payload.get("nodes", []):
            copy = dict(node)
            copy["id"] = node["id"] + suffix
            copy["project"] = project_id
            nodes.append(copy)
            if not node.get("unreviewed") or node.get("type") == "UnreviewedBatch":
                edges.append({"source": copy["id"], "relation": "in_project", "target": hub})
        for edge in payload.get("edges", []):
            edges.append({"source": edge["source"] + suffix, "relation": edge["relation"], "target": edge["target"] + suffix})
        for key in totals:
            totals[key] += int(pending.get(key) or 0)
        per_project.append({"project_id": project_id, "reviewed": len(reviewed), "unreviewed_total": int(pending.get("total") or 0),
                            "unreviewed_shown": int(pending.get("shown") or 0), "unreviewed_clustered": int(pending.get("clustered") or 0),
                            "unreviewed_nodes": len(unreviewed)})
    totals["cap"] = "per project"
    meta = {
        "project": f"All projects ({len(per_project)} of {len(results)})",
        "version": "0.12.1", "privacy": "Principal-filtered snapshot",
        "pending": totals, "projects": per_project, "skipped": skipped,
        "reviewed_total": sum(row["reviewed"] for row in per_project),
    }
    return {"meta": meta, "nodes": nodes, "edges": edges}


def build_all_projects_html(
    vault_root_arg: Path,
    project_ids: list,
    principal: str,
    output_arg: Path,
    include_pending: bool = True,
    progress=None,
    workers: int = ALL_PROJECTS_WORKERS,
) -> Path:
    """Build one merged page for several projects, in parallel, owner-only.

    Each project goes through the same snapshot/filter/pending path as a
    single-project export (with a smaller per-project cap so the merged graph
    stays responsive).  A project that is locked by a writer or cannot be
    snapshotted is listed in ``meta.skipped`` instead of failing the page.
    ``progress(done, total, project_id, ok)`` is called as each finishes.
    """
    _validate_principal(principal)
    ids = list(dict.fromkeys(project_ids))
    if not ids:
        raise LocalSnapshotError("no projects selected")
    for project_id in ids:
        if not PROJECT_ID_RE.fullmatch(project_id) or project_id in {".", ".."}:
            raise LocalSnapshotError("invalid project ID")
    vault_root = _resolve_vault(vault_root_arg)
    output = _validate_output(output_arg, vault_root)
    cap = max(ALL_PROJECTS_MIN_CAP, ALL_PROJECTS_SHOWN_BUDGET // len(ids))

    def one(project_id):
        try:
            root = _resolve_project(vault_root, project_id)
            return project_id, _project_payload(vault_root, root, project_id, principal, include_pending, cap), ""
        except LocalSnapshotError as exc:
            return project_id, None, str(exc)

    results = {}
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = {pool.submit(one, project_id): project_id for project_id in ids}
        for done, future in enumerate(as_completed(futures), 1):
            project_id, payload, error = future.result()
            results[project_id] = (project_id, payload, error)
            if progress:
                progress(done, len(ids), project_id, payload is not None)
    merged = merge_project_payloads([results[project_id] for project_id in ids])
    merged["meta"]["pending"]["cap"] = cap
    _render_and_write(merged, output)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-root", required=True, type=Path, help="explicit local LLM-Brain vault root")
    parser.add_argument("--project-id", required=True, action="append",
                        help="exact registered project ID; repeat it to merge several projects into one page")
    parser.add_argument("--principal", required=True, help="existing LLM-Brain principal filter (not authentication)")
    parser.add_argument("--output", required=True, type=Path, help="new absolute .html output path outside the vault")
    args = parser.parse_args()
    try:
        if len(args.project_id) == 1:
            result = build_local_snapshot_html(args.vault_root, args.project_id[0], args.principal, args.output)
        else:
            def report(done, total, project_id, ok):
                print(f"ne-progress {done}/{total} {'ok' if ok else 'skipped'}", file=sys.stderr, flush=True)
            result = build_all_projects_html(args.vault_root, args.project_id, args.principal, args.output, progress=report)
    except LocalSnapshotError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
