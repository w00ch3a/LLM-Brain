import json
import re
import unittest
from pathlib import Path


VISUALIZER = Path(__file__).resolve().parents[1]
DEMO = VISUALIZER / "demo" / "neural-expansion-synthetic.html"


class StandaloneDemoTests(unittest.TestCase):
    def test_committed_demo_matches_the_builder(self):
        import sys

        sys.path.insert(0, str(VISUALIZER))
        try:
            from build_demo import render_demo
        finally:
            sys.path.pop(0)
        self.assertEqual(DEMO.read_text(encoding="utf-8"), render_demo(),
                         "run: python3 neural-expansion/build_demo.py")

    def app_scripts(self):
        html = DEMO.read_text(encoding="utf-8")
        scripts = re.findall(r"<script>\s*(.*?)</script>", html, re.DOTALL)
        return html, "\n".join(scripts)

    def test_embedded_fixture_is_exact_and_closed(self):
        html = DEMO.read_text(encoding="utf-8")
        match = re.search(
            r'<script type="application/json" id="synthetic-fixture">(.*?)</script>',
            html,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        inline = match.group(1)
        fixture = json.loads(inline)
        source = json.loads((VISUALIZER / "fixtures" / "synthetic.json").read_text())
        self.assertEqual(fixture, source)
        ids = {node["id"] for node in fixture["nodes"]}
        self.assertTrue(all(edge["source"] in ids and edge["target"] in ids for edge in fixture["edges"]))
        self.assertNotIn("</script", inline.lower())
        self.assertNotIn("<", inline)

    def test_no_network_or_external_asset_path(self):
        html, app = self.app_scripts()
        self.assertNotRegex(app, r"\bfetch\s*\(|XMLHttpRequest|WebSocket")
        self.assertNotRegex(
            html,
            r"<(?:script|link|img|iframe|source)\b[^>]*\b(?:src|href)\s*=",
        )
        self.assertIn("SYNTHETIC DEMO · OFFLINE", html)
        self.assertIn("NEURAL EXPANSION", html)
        self.assertIn("<title>LLM-Brain · Neural Expansion</title>", html)

    def test_controls_accessibility_and_responsive_features_remain(self):
        html, app = self.app_scripts()
        for feature in (
            'id="search"',
            'id="filter"',
            'id="details"',
            'id="relations"',
            'id="toggleList" type="button" aria-controls="list" aria-expanded="false"',
            'setAttribute("aria-expanded", String(expanded))',
            '<button type="button" class="rel"',
            "pointerdown",
            "pointermove",
            'addEventListener("wheel"',
            "value=\"history\">History",
            "value=\"pending\">Pending",
            "prefers-reduced-motion: reduce",
            "grid-template-rows: minmax(310px, 55vh)",
            "height: calc(100% - 120px); grid-template-columns",
            "getContext(\"webgl\"",
            "ArrowLeft",
        ):
            self.assertIn(feature, html + app, feature)

    def test_scaffold_links_are_precomputed_outside_redraw(self):
        _html, app = self.app_scripts()
        draw_at = app.index("function draw(time = 0)")
        setup, renderer = app[:draw_at], app[draw_at:]
        self.assertIn("const brainModel =", setup)
        self.assertIn("brainModel.links", setup)
        self.assertNotIn(".sort((a,b)=>a.d-b.d)", renderer)

    def test_visible_render_records_keep_layout_coordinates(self):
        _html, app = self.app_scripts()
        self.assertIn("const graph = { ...data, nodes };", app)
        self.assertIn("Core.visibleGraph(graph, search.value, filter.value)", app)

    def test_clear_resets_selection_and_resize_rebases_camera_to_fit(self):
        _html, app = self.app_scripts()
        clear_at = app.index("function clearSearchAndSelection()")
        clear_end = app.index("\n  }", clear_at)
        self.assertIn("selected = null;", app[clear_at:clear_end])
        self.assertIn("hover = null;", app[clear_at:clear_end])
        self.assertIn("Core.zoomForResize(camera.zoom, fitZoom, nextFitZoom)", app)
        self.assertIn("Core.fitZoom(nodes, width, height, measureLabel)", app)
        self.assertIn("Core.labelPosition(point.x, width, ctx.measureText(node.title).width)", app)
        self.assertIn("const layer = Core.recordLayer(node);", app)
        self.assertIn("<span class=\"list-title\">", app)
        self.assertIn("@media (min-width: 681px) and (max-width: 900px)", _html)


if __name__ == "__main__":
    unittest.main()
