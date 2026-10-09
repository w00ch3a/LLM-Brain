(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.LLMBrainNeuralExpansionCore = api;
})(typeof globalThis === "undefined" ? this : globalThis, function () {
  "use strict";

  const MIN_ZOOM = 0.45;
  const MAX_ZOOM = 2.5;

  function visibleGraph(data, query = "", status = "all") {
    const needle = String(query || "").trim().toLocaleLowerCase();
    const nodes = (data?.nodes || []).filter((node) => {
      if (status !== "all" && node.status !== status) return false;
      if (!needle) return true;
      return [node.id, node.title, node.type, node.status, node.provenance, node.excerpt]
        .join(" ")
        .toLocaleLowerCase()
        .includes(needle);
    });
    const ids = new Set(nodes.map((node) => node.id));
    const edges = (data?.edges || []).filter((edge) => ids.has(edge.source) && ids.has(edge.target));
    return { nodes, edges };
  }

  function layoutNodes(sourceNodes) {
    const count = sourceNodes.length;
    if (!count) return [];
    const goldenAngle = Math.PI * (3 - Math.sqrt(5));
    return sourceNodes.map((node, index) => {
      const yFraction = 1 - 2 * (index + 0.5) / count;
      const ring = Math.sqrt(Math.max(0, 1 - yFraction * yFraction));
      const angle = goldenAngle * index + (index % 2) * 0.16;
      const shell = 166 + (index % 3) * 15;
      return {
        ...node,
        base: {
          x: Math.cos(angle) * ring * shell,
          y: yFraction * 142,
          z: Math.sin(angle) * ring * shell * 0.62,
        },
        p: {
          x: Math.cos(angle) * ring * shell,
          y: yFraction * 142,
          z: Math.sin(angle) * ring * shell * 0.62,
        },
      };
    });
  }

  function projectPoint(point, camera, width, height) {
    const yaw = camera.yaw || 0;
    const tilt = camera.tilt || 0;
    const zoom = camera.zoom || 1;
    const cosYaw = Math.cos(yaw);
    const sinYaw = Math.sin(yaw);
    const x = point.x * cosYaw - point.z * sinYaw;
    const z = point.x * sinYaw + point.z * cosYaw;
    const y = point.y * Math.cos(tilt) - z * Math.sin(tilt);
    const depth = point.y * Math.sin(tilt) + z * Math.cos(tilt);
    const scale = zoom * 470 / Math.max(130, 470 + depth);
    return {
      x: width / 2 + x * scale,
      y: height / 2 - y * scale,
      scale,
      z: depth,
    };
  }

  function clampZoom(value) {
    return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, value));
  }

  function zoomBy(current, deltaY) {
    return clampZoom(current * Math.exp(-deltaY * 0.001));
  }

  function fitZoom(nodes, width, height, measureLabel) {
    const points = nodes.map((node) => node.base || node.p).filter(Boolean);
    const halfWidth = Math.max(190, ...points.map((point) => Math.abs(point.x) + 55));
    const halfHeight = Math.max(160, ...points.map((point) => Math.abs(point.y) + 55));
    const availableWidth = Math.max(240, width - 116);
    const availableHeight = Math.max(220, height - 170);
    const geometryFit = clampZoom(Math.min(2.25, availableWidth / (2 * halfWidth), availableHeight / (2 * halfHeight)));
    if (!nodes.length || width <= 0 || height <= 0) return geometryFit;

    const labelsFit = (zoom) => nodes.every((node) => {
      const point = projectPoint(node.base || node.p, { yaw: 0, tilt: 0, zoom }, width, height);
      const fontSize = Math.max(10, 10.5 * point.scale);
      const title = String(node.title || "");
      const textWidth = measureLabel
        ? measureLabel(title, fontSize)
        : title.length * fontSize * 0.58;
      // Leave enough room to keep the entire label readable beside its node.
      return Math.abs(point.x - width / 2) + textWidth / 2 + 18 <= width / 2;
    });

    if (labelsFit(geometryFit)) return geometryFit;
    if (!labelsFit(MIN_ZOOM)) return MIN_ZOOM;
    let low = MIN_ZOOM;
    let high = geometryFit;
    for (let step = 0; step < 20; step += 1) {
      const middle = (low + high) / 2;
      if (labelsFit(middle)) low = middle;
      else high = middle;
    }
    return low;
  }

  function labelPosition(pointX, width, textWidth, margin = 12, offset = 12) {
    const available = Math.max(0, width - 2 * margin);
    if (textWidth > available) return { x: margin, align: "left", maxWidth: available };

    const dx = pointX - width / 2;
    const preferred = Math.abs(dx) < 20 ? "center" : dx > 0 ? "left" : "right";
    const x = preferred === "center" ? pointX : pointX + Math.sign(dx) * offset;
    if (preferred === "center") {
      return {
        x: Math.max(margin + textWidth / 2, Math.min(width - margin - textWidth / 2, pointX)),
        align: "center",
      };
    }
    const fits = preferred === "left"
      ? x >= margin && x + textWidth <= width - margin
      : x - textWidth >= margin && x <= width - margin;
    if (fits) return { x, align: preferred };
    return {
      x: Math.max(margin + textWidth / 2, Math.min(width - margin - textWidth / 2, pointX)),
      align: "center",
    };
  }

  function nearestNode(nodes, x, y, project, threshold = 22) {
    let nearest = null;
    let distance = threshold;
    for (const node of nodes) {
      const point = project(node.p);
      const candidate = Math.hypot(point.x - x, point.y - y);
      const hitRadius = Math.max(distance, 10 + 5 * point.scale);
      if (candidate < hitRadius) {
        nearest = node;
        distance = candidate;
      }
    }
    return nearest;
  }

  function usesReducedMotion(mediaQuery) {
    return Boolean(mediaQuery && mediaQuery.matches);
  }

  function recordLayer(node) {
    if (node?.type === "AssociativeProjection") return "Derived projection";
    if (String(node?.id || "").startsWith("review/")) return "Review / quarantine";
    if (String(node?.id || "").startsWith("episodes/")) return "Append-only history";
    if (String(node?.id || "").startsWith("okf/")) return "Canonical OKF";
    return "Derived / external";
  }

  function zoomForResize(zoom, previousFit, nextFit) {
    if (!(previousFit > 0) || !(nextFit > 0)) return clampZoom(zoom);
    return clampZoom(zoom * nextFit / previousFit);
  }

  return {
    MIN_ZOOM,
    MAX_ZOOM,
    clampZoom,
    fitZoom,
    labelPosition,
    layoutNodes,
    nearestNode,
    projectPoint,
    recordLayer,
    usesReducedMotion,
    visibleGraph,
    zoomForResize,
    zoomBy,
  };
});
