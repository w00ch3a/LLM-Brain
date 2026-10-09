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
from pathlib import Path


VISUALIZER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(VISUALIZER))

from build_demo import render_html  # noqa: E402
from export_graph import ExportError, build_export  # noqa: E402
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


def build_local_snapshot_html(
    vault_root_arg: Path,
    project_id: str,
    principal: str,
    output_arg: Path,
) -> Path:
    """Read one explicit project snapshot, filter it, and write owner-only HTML."""
    if not PROJECT_ID_RE.fullmatch(project_id) or project_id in {".", ".."}:
        raise LocalSnapshotError("invalid project ID")
    _validate_principal(principal)
    if not vault_root_arg.is_absolute() or vault_root_arg.is_symlink():
        raise LocalSnapshotError("vault root must be an absolute, non-symlink directory")
    try:
        vault_root = vault_root_arg.resolve(strict=True)
    except OSError as exc:
        raise LocalSnapshotError("vault root is unavailable") from exc
    if not vault_root.is_dir():
        raise LocalSnapshotError("vault root is unavailable")

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

    output = _validate_output(output_arg, vault_root)
    _assert_no_writer(vault_root, project_id)
    try:
        with tempfile.TemporaryDirectory(prefix="llm-brain-neural-expansion-") as private_temp:
            private_root = Path(private_temp)
            os.chmod(private_root, 0o700)
            package = private_root / "snapshot"
            build_snapshot(project_root, package)
            payload = build_export(package, principal)
            _assert_no_writer(vault_root, project_id)
            page = render_html(
                payload,
                "NEURAL EXPANSION · LOCAL SNAPSHOT · PRINCIPAL-FILTERED · READ ONLY",
            )
            _write_owner_only_new_file(output, page)
    except (ExportError, OSError) as exc:
        raise LocalSnapshotError("consistent filtered snapshot unavailable") from exc
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-root", required=True, type=Path, help="explicit local LLM-Brain vault root")
    parser.add_argument("--project-id", required=True, help="exact registered project ID")
    parser.add_argument("--principal", required=True, help="existing LLM-Brain principal filter (not authentication)")
    parser.add_argument("--output", required=True, type=Path, help="new absolute .html output path outside the vault")
    args = parser.parse_args()
    try:
        result = build_local_snapshot_html(args.vault_root, args.project_id, args.principal, args.output)
    except LocalSnapshotError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
