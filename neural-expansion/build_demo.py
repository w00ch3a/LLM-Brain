#!/usr/bin/env python3
"""Build the single-file, offline Neural Expansion synthetic demo from the viewer source."""

from __future__ import annotations

import json
from html import escape
from pathlib import Path


ROOT = Path(__file__).resolve().parent
INDEX = ROOT / "index.html"
CORE = ROOT / "neural-core.js"
VIEWER = ROOT / "viewer.js"
FIXTURE = ROOT / "fixtures" / "synthetic.json"
OUTPUT = ROOT / "demo" / "neural-expansion-synthetic.html"


def _script_json(payload: dict) -> str:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return (
        encoded.replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def render_html(payload: dict, banner_text: str) -> str:
    """Inline one already-filtered projection into the local Neural Expansion template."""
    html = INDEX.read_text(encoding="utf-8")
    expected = _script_json(payload)
    start = html.index('<script type="application/json" id="synthetic-fixture">')
    body_start = html.index(">", start) + 1
    body_end = html.index("</script>", body_start)
    html = html[:body_start] + expected + html[body_end:]

    for relative, path in (("./neural-core.js", CORE), ("./viewer.js", VIEWER)):
        marker = f'<script src="{relative}" defer></script>'
        if marker not in html:
            raise ValueError(f"missing local script reference: {relative}")
        source = path.read_text(encoding="utf-8")
        html = html.replace(marker, f"<script>\n{source}\n</script>", 1)

    banner = (
        '<div class="demo-banner" role="note">'
        f"{escape(banner_text)}"
        "</div>\n"
    )
    html = html.replace("  <main>", banner + "  <main>", 1)
    html = html.replace("script-src 'self'", "script-src 'unsafe-inline'", 1)
    html = html.replace(
      "    @media (prefers-reduced-motion: reduce) {",
      "    .demo-banner { position: relative; z-index: 5; height: 22px; padding: 3px 8px; "
      "border-bottom: 1px solid #6b4a61; background: #2a1724; color: #ffd8e0; "
      "font-size: 9px; letter-spacing: .08em; text-align: center; text-transform: uppercase; }\n"
      "    @media (prefers-reduced-motion: reduce) {",
        1,
    )
    html = html.replace("height: calc(100% - 70px);", "height: calc(100% - 92px);", 1)
    html = html.replace(
        "height: calc(100% - 98px); grid-template-columns",
        "height: calc(100% - 120px); grid-template-columns",
        1,
    )
    return html


DEMO_BANNER = "NEURAL EXPANSION · SYNTHETIC DEMO · OFFLINE"


def render_demo() -> str:
    """Render the synthetic demo page from the bundled synthetic fixture only."""
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    return render_html(fixture, DEMO_BANNER)


def build(output: Path = OUTPUT) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_demo(), encoding="utf-8")
    return output


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT, help="where to write the synthetic demo page")
    print(build(parser.parse_args().output))
