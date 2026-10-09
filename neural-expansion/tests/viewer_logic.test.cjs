const test = require("node:test");
const assert = require("node:assert/strict");
const Core = require("../neural-core.js");

const graph = {
  nodes: [
    { id: "okf/a.md", title: "Alpha", type: "Claim", status: "stable", excerpt: "first" },
    { id: "okf/b.md", title: "Beta", type: "Decision", status: "pending", excerpt: "second" },
    { id: "okf/c.md", title: "Gamma", type: "Concept", status: "stable", excerpt: "third" },
  ],
  edges: [
    { source: "okf/a.md", relation: "supports", target: "okf/c.md" },
    { source: "okf/a.md", relation: "links_to", target: "okf/b.md" },
  ],
};

test("search and status filters retain only visible nodes and their internal edges", () => {
  const filtered = Core.visibleGraph(graph, "ALPHA", "all");
  assert.deepEqual(filtered.nodes.map((node) => node.id), ["okf/a.md"]);
  assert.deepEqual(filtered.edges, []);

  const stable = Core.visibleGraph(graph, "", "stable");
  assert.deepEqual(stable.nodes.map((node) => node.id), ["okf/a.md", "okf/c.md"]);
  assert.deepEqual(stable.edges, [graph.edges[0]]);
});

test("layout is deterministic and distributes the shell around the brain", () => {
  const first = Core.layoutNodes(graph.nodes);
  const second = Core.layoutNodes(graph.nodes);
  assert.deepEqual(first.map((node) => node.base), second.map((node) => node.base));
  assert.ok(first.every((node) => Number.isFinite(node.p.x + node.p.y + node.p.z)));
  assert.ok(first.some((node) => node.base.x < 0));
  assert.ok(first.some((node) => node.base.x > 0));
});

test("visibility filtering keeps the spatial coordinates used by rendering", () => {
  const layout = Core.layoutNodes(graph.nodes);
  const visible = Core.visibleGraph({ ...graph, nodes: layout }, "alpha", "all");
  assert.equal(visible.nodes.length, 1);
  assert.deepEqual(visible.nodes[0].p, layout[0].p);
  assert.deepEqual(visible.nodes[0].base, layout[0].base);
});

test("projected points respond to yaw, tilt, and zoom", () => {
  const point = { x: 35, y: 28, z: -48 };
  const baseline = Core.projectPoint(point, { yaw: 0, tilt: 0, zoom: 1 }, 800, 600);
  const orbited = Core.projectPoint(point, { yaw: 0.7, tilt: 0.35, zoom: 1 }, 800, 600);
  const enlarged = Core.projectPoint(point, { yaw: 0, tilt: 0, zoom: 1.5 }, 800, 600);
  assert.notDeepEqual([baseline.x, baseline.y], [orbited.x, orbited.y]);
  assert.ok(Math.abs(enlarged.x - 400) > Math.abs(baseline.x - 400));
  assert.ok(Math.abs(enlarged.y - 300) > Math.abs(baseline.y - 300));
});

test("zoom clamps and graph fit stays inside supported bounds", () => {
  assert.equal(Core.zoomBy(1, -100000), Core.MAX_ZOOM);
  assert.equal(Core.zoomBy(1, 100000), Core.MIN_ZOOM);
  const layout = Core.layoutNodes(graph.nodes);
  const zoom = Core.fitZoom(layout, 1180, 820);
  assert.ok(zoom >= Core.MIN_ZOOM && zoom <= Core.MAX_ZOOM);
});

test("resize scales the camera with the new viewport fit", () => {
  const desktopFit = Core.fitZoom(Core.layoutNodes(graph.nodes), 1180, 650);
  const tabletFit = Core.fitZoom(Core.layoutNodes(graph.nodes), 478, 954);
  assert.ok(tabletFit < desktopFit);
  assert.equal(Core.zoomForResize(desktopFit, desktopFit, tabletFit), tabletFit);
  assert.equal(Core.zoomForResize(desktopFit * 1.4, desktopFit, tabletFit), tabletFit * 1.4);
});

test("fit accounts for long labels and edge placement keeps full text onscreen", () => {
  const fixture = require("../fixtures/synthetic.json");
  const layout = Core.layoutNodes(fixture.nodes);
  const width = 390;
  const height = 464;
  const measure = (title, fontSize) => title.length * fontSize * 0.7;
  const fit = Core.fitZoom(layout, width, height, measure);
  assert.ok(fit < Core.fitZoom(layout, width, height), "long labels reduce the fitted camera zoom");
  for (const node of layout) {
    const point = Core.projectPoint(node.p, { yaw: 0, tilt: 0, zoom: fit }, width, height);
    const size = Math.max(10, 10.5 * point.scale);
    const labelWidth = measure(node.title, size);
    const position = Core.labelPosition(point.x, width, labelWidth);
    const renderedWidth = Math.min(labelWidth, width - 24);
    const left = position.align === "center" ? position.x - renderedWidth / 2
      : position.align === "right" ? position.x - renderedWidth : position.x;
    assert.ok(left >= 12 - 0.001, `${node.title} label starts at ${left}`);
    assert.ok(left + renderedWidth <= width - 12 + 0.001, `${node.title} label ends offscreen`);
  }
});

test("derived projections remain classified as derived inside the OKF tree", () => {
  assert.equal(Core.recordLayer({ id: "okf/projections/assoc.md", type: "AssociativeProjection" }), "Derived projection");
  assert.equal(Core.recordLayer({ id: "okf/claims/a.md", type: "Claim" }), "Canonical OKF");
  assert.equal(Core.recordLayer({ id: "review/item.md", type: "ReviewItem" }), "Review / quarantine");
});

test("node hit testing chooses the closest projected visible record", () => {
  const layout = Core.layoutNodes(graph.nodes);
  const target = layout[1];
  const camera = { yaw: 0.4, tilt: 0.2, zoom: 1.3 };
  const project = (point) => Core.projectPoint(point, camera, 900, 680);
  const screen = project(target.p);
  assert.equal(Core.nearestNode(layout, screen.x + 1, screen.y - 1, project), target);
  assert.equal(Core.nearestNode(layout, -100, -100, project), null);
});

test("reduced-motion preference is honored", () => {
  assert.equal(Core.usesReducedMotion({ matches: true }), true);
  assert.equal(Core.usesReducedMotion({ matches: false }), false);
  assert.equal(Core.usesReducedMotion(null), false);
});
