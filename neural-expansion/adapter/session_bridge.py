#!/usr/bin/env python3
"""Framework-neutral, read-only seam for a trusted local application session.

This module intentionally starts no server and accepts no request-supplied
principal, project ID, path, or generation. A host application must provide
its already-authenticated principal and authorized project through trusted
server-side callbacks, plus a core snapshot stager. The core CLI pins the
project generation under its lock and writes the package on the project's
filesystem. The filtered projection is returned after the unfiltered package
has been removed from that same filesystem.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable, ContextManager

from export_graph import build_core_snapshot_export


class SessionBridgeError(RuntimeError):
    """Safe, non-path-bearing integration error."""


PrincipalProvider = Callable[[], str | None]
ProjectProvider = Callable[[], Path]
SnapshotPackageStager = Callable[[Path], ContextManager[Path]]


NO_STORE_HEADERS = {
    "Cache-Control": "private, no-store, max-age=0",
    "Pragma": "no-cache",
    "Vary": "Cookie",
}


def _valid_principal(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and value == value.strip()
        and not any(ord(character) < 32 for character in value)
    )


def safe_script_json(payload: dict[str, Any]) -> str:
    """Serialize filtered data for a non-executable JSON script element."""
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return (
        encoded.replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


class ReadOnlySessionBridge:
    """Build one filtered projection from a trusted host session.

    The provider callbacks must be closures over the host's authenticated
    session. They must not read identity or project selection from browser
    parameters. `snapshot_package_stager` invokes the core-owned snapshot
    command, which holds the canonical project lock and stages on the source
    project's filesystem. Do not wrap it in a second project lock.
    """

    def __init__(
        self,
        *,
        authenticated_principal: PrincipalProvider,
        authorized_project_root: ProjectProvider,
        snapshot_package_stager: SnapshotPackageStager,
    ) -> None:
        if not callable(authenticated_principal) or not callable(authorized_project_root) or not callable(snapshot_package_stager):
            raise TypeError("trusted session, project, and core snapshot stager are required")
        self._principal_provider = authenticated_principal
        self._project_provider = authorized_project_root
        self._snapshot_package_stager = snapshot_package_stager

    def projection(self) -> dict[str, Any]:
        """Return a single principal-filtered projection for the current session."""
        try:
            principal = self._principal_provider()
        except Exception as exc:
            raise SessionBridgeError("authenticated session unavailable") from exc
        if not _valid_principal(principal):
            raise SessionBridgeError("authenticated principal required")

        try:
            source_root = Path(self._project_provider())
        except Exception as exc:
            raise SessionBridgeError("authorized project unavailable") from exc
        if not source_root.is_absolute():
            raise SessionBridgeError("authorized project unavailable")

        try:
            with self._snapshot_package_stager(source_root) as package:
                payload = build_core_snapshot_export(package, principal, source_root.name)
        except Exception as exc:
            if isinstance(exc, SessionBridgeError):
                raise
            # The host must log its own safe diagnostic; never return project
            # paths, note text, hidden labels, or resolver internals to a client.
            raise SessionBridgeError("consistent filtered snapshot unavailable") from exc
        return payload

    def json_payload(self) -> str:
        return safe_script_json(self.projection())
