"""LLM-Brain dashboard API: builds a Neural Expansion page for this profile.

Mounted by Hermes at ``/api/plugins/llm-brain/`` (user plugins only after they
are in ``plugins.enabled``).  It shares ``build_neural_expansion`` with the
``/neural-expansion`` slash command, so both surfaces have the same gates: the
synthetic demo is always available; the real brain needs
``neural_expansion_export: true`` and is principal-filtered.  Requests from
non-loopback clients are refused, and the page is returned for a sandboxed
iframe with no network access.
"""

from __future__ import annotations

import importlib.util
import ipaddress
import sys
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request

router = APIRouter()
_MAX_PAGE_BYTES = 32 * 1024 * 1024


def _plugin():
    name = "llm_brain_hermes_dashboard_backend"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent.parent / "__init__.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _require_loopback(request: Request) -> None:
    host = request.client.host if request.client else ""
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host == "localhost"
    if not loopback:
        raise HTTPException(status_code=403, detail="Neural Expansion is served to loopback clients only")


@router.get("/status")
def status(request: Request):
    _require_loopback(request)
    plugin = _plugin()
    config = plugin._load_config(plugin._registration_hermes_home())
    return {"demo": True, "export_enabled": config.get("neural_expansion_export") is True,
            "cli_found": bool(plugin._find_cli(config))}


_CSP_META = ('<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
             'script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; img-src data:; connect-src \'none\'">')


def with_csp(page: str) -> str:
    """Pin a no-network CSP inside the page (it is shown in a sandboxed srcdoc iframe)."""
    lowered = page.lower()
    index = lowered.find("<head>")
    if index < 0:
        return _CSP_META + page
    return page[: index + 6] + _CSP_META + page[index + 6:]


@router.get("/view")
def view(request: Request, mode: str = "demo"):
    _require_loopback(request)
    result = _plugin().build_neural_expansion(mode)
    if result.get("status") != "ok":
        raise HTTPException(status_code=409 if result.get("status") == "disabled" else 500, detail=result.get("error", "unavailable"))
    path = Path(result["path"])
    if path.stat().st_size > _MAX_PAGE_BYTES:
        raise HTTPException(status_code=413, detail="page too large")
    return {"status": "ok", "mode": result["mode"], "data": result["data"], "file": path.name,
            "html": with_csp(path.read_text(encoding="utf-8"))}
