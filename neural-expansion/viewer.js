(() => {
  "use strict";

  const Core = window.LLMBrainNeuralExpansionCore;
  const palette = {
    Claim: "#6fe8ff",
    Concept: "#62d6d1",
    Procedure: "#84e5b8",
    Decision: "#ffd080",
    Fact: "#a99cff",
    Episode: "#a8bdcd",
    ReviewItem: "#ff7889",
    AssociativeProjection: "#e58cff",
    default: "#82b9ff",
  };
  const relationColors = {
    supports: "#71e7ff",
    derived_from: "#a891ff",
    depends_on: "#9cc4ff",
    conflicts_with: "#ff7a8b",
    associates: "#e18cff",
    proposed_for_review: "#ffc978",
    historical_context: "#9fb4c6",
    contains: "#63d8ce",
  };
  const byId = (id) => document.getElementById(id);
  const canvas = byId("graph");
  const brainCanvas = byId("brain");
  const ctx = canvas.getContext("2d");
  const details = byId("details");
  const relationBox = byId("relations");
  const search = byId("search");
  const filter = byId("filter");
  const listElement = byId("list");
  const listButton = byId("toggleList");
  const recordHud = byId("recordHud");
  const sourceBadge = byId("sourceBadge");
  const counts = byId("counts");
  const reducedQuery = window.matchMedia?.("(prefers-reduced-motion: reduce)") || { matches: false };
  let prefersReducedMotion = Core.usesReducedMotion(reducedQuery);
  let data;
  try {
    data = JSON.parse(byId("synthetic-fixture").textContent);
  } catch {
    data = { meta: { project: "Synthetic demo", privacy: "Synthetic only" }, nodes: [], edges: [] };
  }
  if (!Array.isArray(data.nodes) || !Array.isArray(data.edges)) {
    data = { meta: { project: "Synthetic demo", privacy: "Synthetic only" }, nodes: [], edges: [] };
  }
  const nodes = Core.layoutNodes(data.nodes);
  // Keep the spatial fields attached while filtering: draw(), hit testing, and
  // selection all project these same laid-out records into screen space.
  const graph = { ...data, nodes };
  const idMap = new Map(nodes.map((node) => [node.id, node]));
  const edges = data.edges.filter((edge) => idMap.has(edge.source) && idMap.has(edge.target));
  const camera = { yaw: 0, tilt: 0, zoom: 1 };
  let selected = null;
  let hover = null;
  let drag = null;
  let width = 0;
  let height = 0;
  let fitZoom = 1;
  let hasSized = false;
  let pixelRatio = 1;
  let animationFrame = 0;
  let lastFrame = 0;

  const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
  const nodeColor = (node) => palette[node.type] || palette.default;
  const visible = () => Core.visibleGraph(graph, search.value, filter.value);
  const project = (point) => Core.projectPoint(point, camera, width, height);
  function measureLabel(title, fontSize) {
    ctx.font = `650 ${fontSize}px system-ui, sans-serif`;
    return ctx.measureText(title).width;
  }

  function hexRGB(hex) {
    return [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16) / 255);
  }

  function buildBrainBuffers() {
    const positions = [];
    const normals = [];
    const colors = [];
    const indices = [];
    function ellipsoid(center, radius, color, phase, foldAmount, rows = 40, columns = 72) {
      const [cr, cg, cb] = hexRGB(color);
      const base = positions.length / 3;
      for (let row = 0; row <= rows; row += 1) {
        const latitude = -Math.PI / 2 + Math.PI * row / rows;
        const cLat = Math.cos(latitude);
        for (let column = 0; column <= columns; column += 1) {
          const longitude = 2 * Math.PI * column / columns;
          const ridge = Math.sin(longitude * 7 + phase + Math.sin(latitude * 3.4) * 1.65)
            * Math.cos(latitude * 5.1)
            + 0.42 * Math.sin(longitude * 13 - latitude * 4.7 + phase);
          const fold = 1 + foldAmount * ridge;
          const nx = cLat * Math.cos(longitude);
          const ny = Math.sin(latitude);
          const nz = cLat * Math.sin(longitude);
          positions.push(
            center[0] + radius[0] * nx * fold,
            center[1] + radius[1] * ny * fold,
            center[2] + radius[2] * nz * fold,
          );
          const normal = [nx / radius[0], ny / radius[1], nz / radius[2]];
          const normalLength = Math.hypot(...normal) || 1;
          normals.push(normal[0] / normalLength, normal[1] / normalLength, normal[2] / normalLength);
          const cortex = 0.78 + 0.17 * Math.max(0, ridge) + 0.06 * Math.sin(latitude * 9 + longitude * 2 + phase);
          colors.push(cr * cortex, cg * cortex, cb * cortex);
        }
      }
      for (let row = 0; row < rows; row += 1) {
        for (let column = 0; column < columns; column += 1) {
          const a = base + row * (columns + 1) + column;
          const b = a + columns + 1;
          indices.push(a, b, a + 1, a + 1, b, b + 1);
        }
      }
    }
    // The paired, folded ellipsoids form the cerebral hemispheres. The smaller
    // posterior lobe and stem make the silhouette read as a brain, not a globe.
    ellipsoid([-22, 4, 0], [88, 69, 54], "#347f9e", 0.35, 0.036);
    ellipsoid([22, 4, 0], [88, 69, 54], "#4d5f9d", 1.1, 0.036);
    ellipsoid([0, -53, 12], [39, 23, 30], "#596f9e", 0.8, 0.05, 28, 48);
    ellipsoid([0, -78, 17], [15, 32, 17], "#3c638d", 0.2, 0.025, 24, 40);
    return {
      positions: new Float32Array(positions),
      normals: new Float32Array(normals),
      colors: new Float32Array(colors),
      indices: new Uint16Array(indices),
    };
  }

  function createBrainRenderer(target) {
    const gl = target.getContext("webgl", { alpha: true, antialias: true, depth: true, premultipliedAlpha: false });
    if (!gl) return null;
    const vertexSource = `
      attribute vec3 aPosition;
      attribute vec3 aNormal;
      attribute vec3 aColor;
      uniform float uYaw;
      uniform float uTilt;
      uniform float uZoom;
      uniform vec2 uResolution;
      uniform float uTime;
      varying vec3 vNormal;
      varying vec3 vColor;
      varying float vDepth;
      void main() {
        float cy = cos(uYaw), sy = sin(uYaw);
        float ct = cos(uTilt), st = sin(uTilt);
        float x = aPosition.x * cy - aPosition.z * sy;
        float z0 = aPosition.x * sy + aPosition.z * cy;
        float y = aPosition.y * ct - z0 * st;
        float z = aPosition.y * st + z0 * ct;
        float perspective = uZoom * 470.0 / max(130.0, 470.0 + z);
        gl_Position = vec4(2.0 * x * perspective / uResolution.x,
                          -2.0 * y * perspective / uResolution.y,
                           clamp(z / 640.0, -0.95, 0.95), 1.0);
        float nx = aNormal.x * cy - aNormal.z * sy;
        float nz0 = aNormal.x * sy + aNormal.z * cy;
        vNormal = normalize(vec3(nx, aNormal.y * ct - nz0 * st, aNormal.y * st + nz0 * ct));
        vColor = aColor;
        vDepth = z;
      }
    `;
    const fragmentSource = `
      precision mediump float;
      varying vec3 vNormal;
      varying vec3 vColor;
      varying float vDepth;
      uniform float uTime;
      void main() {
        vec3 n = normalize(vNormal);
        vec3 light = normalize(vec3(-0.36, 0.62, -0.78));
        float diffuse = max(dot(n, light), 0.0);
        float rim = pow(1.0 - max(dot(n, vec3(0.0, 0.0, -1.0)), 0.0), 2.2);
        float breath = 0.965 + 0.035 * sin(uTime * 0.0012 + vDepth * 0.006);
        vec3 color = vColor * (0.48 + 0.62 * diffuse) + vec3(0.11, 0.47, 0.63) * rim * 0.32;
        gl_FragColor = vec4(color * breath, 0.98);
      }
    `;
    function compile(type, source) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        gl.deleteShader(shader);
        return null;
      }
      return shader;
    }
    const vertexShader = compile(gl.VERTEX_SHADER, vertexSource);
    const fragmentShader = compile(gl.FRAGMENT_SHADER, fragmentSource);
    if (!vertexShader || !fragmentShader) return null;
    const program = gl.createProgram();
    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
    const geometry = buildBrainBuffers();
    const attribute = (name, values, size) => {
      const buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, values, gl.STATIC_DRAW);
      const location = gl.getAttribLocation(program, name);
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, 0, 0);
    };
    const positionBuffer = gl.createBuffer();
    const normalBuffer = gl.createBuffer();
    const colorBuffer = gl.createBuffer();
    const indexBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, geometry.positions, gl.STATIC_DRAW);
    gl.bindBuffer(gl.ARRAY_BUFFER, normalBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, geometry.normals, gl.STATIC_DRAW);
    gl.bindBuffer(gl.ARRAY_BUFFER, colorBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, geometry.colors, gl.STATIC_DRAW);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, geometry.indices, gl.STATIC_DRAW);
    const locations = {
      position: gl.getAttribLocation(program, "aPosition"),
      normal: gl.getAttribLocation(program, "aNormal"),
      color: gl.getAttribLocation(program, "aColor"),
      yaw: gl.getUniformLocation(program, "uYaw"),
      tilt: gl.getUniformLocation(program, "uTilt"),
      zoom: gl.getUniformLocation(program, "uZoom"),
      resolution: gl.getUniformLocation(program, "uResolution"),
      time: gl.getUniformLocation(program, "uTime"),
    };
    function bindAttribute(location, buffer) {
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, 3, gl.FLOAT, false, 0, 0);
    }
    gl.clearColor(0, 0, 0, 0);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.disable(gl.CULL_FACE);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    return {
      resize() {
        const rect = target.getBoundingClientRect();
        target.width = Math.max(1, Math.round(rect.width * pixelRatio));
        target.height = Math.max(1, Math.round(rect.height * pixelRatio));
        gl.viewport(0, 0, target.width, target.height);
      },
      draw(time) {
        if (gl.isContextLost()) return false;
        const rect = target.getBoundingClientRect();
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.useProgram(program);
        bindAttribute(locations.position, positionBuffer);
        bindAttribute(locations.normal, normalBuffer);
        bindAttribute(locations.color, colorBuffer);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
        gl.uniform1f(locations.yaw, camera.yaw);
        gl.uniform1f(locations.tilt, camera.tilt);
        gl.uniform1f(locations.zoom, camera.zoom);
        gl.uniform2f(locations.resolution, Math.max(1, rect.width), Math.max(1, rect.height));
        gl.uniform1f(locations.time, prefersReducedMotion ? 0 : time);
        gl.drawElements(gl.TRIANGLES, geometry.indices.length, gl.UNSIGNED_SHORT, 0);
        return true;
      },
    };
  }

  const brainRenderer = createBrainRenderer(brainCanvas);
  const brainModel = (() => {
    const points = [];
    const links = [];
    const rows = 10;
    const columns = 20;
    for (const side of [-1, 1]) {
      const base = points.length;
      for (let row = 0; row <= rows; row += 1) {
        const latitude = -Math.PI / 2 + Math.PI * row / rows;
        for (let column = 0; column <= columns; column += 1) {
          const longitude = 2 * Math.PI * column / columns;
          const fold = 1 + 0.04 * Math.sin(longitude * 7 + latitude * 3 + side);
          points.push({
            p: {
              x: side * 22 + 88 * Math.cos(latitude) * Math.cos(longitude) * fold,
              y: 68 * Math.sin(latitude) * fold,
              z: 52 * Math.cos(latitude) * Math.sin(longitude) * fold,
            },
            side,
          });
        }
      }
      for (let row = 0; row <= rows; row += 1) {
        for (let column = 0; column <= columns; column += 1) {
          const index = base + row * (columns + 1) + column;
          if (column < columns) links.push([index, index + 1]);
          if (row < rows) links.push([index, index + columns + 1]);
        }
      }
    }
    return { points, links };
  })();

  function drawBrainFallback() {
    const projected = brainModel.points.map((vertex) => ({ ...vertex, screen: project(vertex.p) }));
    ctx.save();
    ctx.lineWidth = 0.55;
    for (const [left, right] of brainModel.links) {
      const a = projected[left].screen;
      const b = projected[right].screen;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.strokeStyle = projected[left].side < 0 ? "#6de4ff25" : "#aa91ff25";
      ctx.stroke();
    }
    for (const vertex of projected) {
      ctx.beginPath();
      ctx.arc(vertex.screen.x, vertex.screen.y, 1.2 * vertex.screen.scale, 0, Math.PI * 2);
      ctx.fillStyle = vertex.side < 0 ? "#5cd8ff42" : "#a26eff42";
      ctx.fill();
    }
    ctx.restore();
  }

  function surfacePoint(side, angle, latitude) {
    const ridge = 0.036 * (
      Math.sin(angle * 7 + side * 0.35 + Math.sin(latitude * 3.4) * 1.65) * Math.cos(latitude * 5.1)
      + 0.42 * Math.sin(angle * 13 - latitude * 4.7 + side * 1.1)
    );
    const fold = 1 + ridge;
    const c = Math.cos(latitude);
    return {
      x: side * (22 + 88 * c * Math.sin(angle) * fold),
      y: 4 + 69 * Math.sin(latitude) * fold,
      z: -54 * c * Math.cos(angle) * fold,
    };
  }

  function drawCortexLines() {
    ctx.save();
    ctx.lineCap = "round";
    for (const side of [-1, 1]) {
      for (let curve = 0; curve < 6; curve += 1) {
        const base = -0.69 + curve * 0.265;
        ctx.beginPath();
        for (let step = 0; step <= 54; step += 1) {
          const angle = 0.08 + 1.36 * step / 54;
          const latitude = base + 0.105 * Math.sin(angle * 3.2 + curve * 0.83)
            + 0.033 * Math.sin(angle * 8.2 + curve * 1.1);
          const p = project(surfacePoint(side, angle, latitude));
          if (step === 0) ctx.moveTo(p.x, p.y);
          else ctx.lineTo(p.x, p.y);
        }
        ctx.strokeStyle = curve % 2 ? "#4bd5ed48" : "#b8a6ff3d";
        ctx.lineWidth = curve % 2 ? 1.15 : 0.9;
        ctx.shadowColor = side < 0 ? "#59deff88" : "#a58cff88";
        ctx.shadowBlur = 4;
        ctx.stroke();
      }
    }
    ctx.beginPath();
    for (let step = 0; step <= 48; step += 1) {
      const y = -60 + 126 * step / 48;
      const fraction = Math.max(0.08, 1 - (y / 74) ** 2);
      const p = project({ x: 1.8 * Math.sin(step * 0.9), y, z: -55 * Math.sqrt(fraction) - 1.5 });
      if (step === 0) ctx.moveTo(p.x, p.y);
      else ctx.lineTo(p.x, p.y);
    }
    ctx.shadowColor = "#04101c";
    ctx.shadowBlur = 5;
    ctx.strokeStyle = "#06101dce";
    ctx.lineWidth = 2.3;
    ctx.stroke();
    ctx.shadowBlur = 0;
    ctx.strokeStyle = "#b4eaff47";
    ctx.lineWidth = 0.6;
    ctx.stroke();
    ctx.restore();
  }

  function drawOrbit(time) {
    const phase = prefersReducedMotion ? 0.42 : time * 0.00012;
    ctx.save();
    ctx.beginPath();
    for (let step = 0; step <= 88; step += 1) {
      const a = Math.PI * 2 * step / 88 + phase;
      const point = project({ x: 160 * Math.cos(a), y: 8 + 114 * Math.sin(a), z: 22 * Math.sin(a + 0.8) });
      if (step === 0) ctx.moveTo(point.x, point.y);
      else ctx.lineTo(point.x, point.y);
    }
    ctx.strokeStyle = "#4abfe22b";
    ctx.lineWidth = 0.8;
    ctx.setLineDash([2, 8]);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.restore();
  }

  function relationColor(relation) {
    return relationColors[relation] || "#82bdde";
  }

  function drawEdge(edge, index, positions, time) {
    const a = positions.get(edge.source);
    const b = positions.get(edge.target);
    if (!a || !b) return;
    const focused = !selected || selected.id === edge.source || selected.id === edge.target;
    const color = relationColor(edge.relation);
    const alpha = focused ? "a8" : "20";
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.strokeStyle = color + (focused ? "32" : "12");
    ctx.lineWidth = focused ? 5.5 : 3;
    ctx.shadowColor = color + "b0";
    ctx.shadowBlur = focused ? 13 : 5;
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.strokeStyle = color + alpha;
    ctx.lineWidth = focused ? 1.05 : 0.7;
    ctx.shadowBlur = 0;
    if (edge.relation === "derived_from" || edge.relation === "historical_context") ctx.setLineDash([4, 5]);
    ctx.stroke();
    ctx.setLineDash([]);
    if (!prefersReducedMotion && focused) {
      const phase = ((time / 1450) + index * 0.271) % 1;
      const x = a.x + (b.x - a.x) * phase;
      const y = a.y + (b.y - a.y) * phase;
      const gradient = ctx.createRadialGradient(x, y, 0, x, y, 8);
      gradient.addColorStop(0, color + "ed");
      gradient.addColorStop(0.25, color + "99");
      gradient.addColorStop(1, color + "00");
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(x, y, 8, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(x, y, 1.6, 0, Math.PI * 2);
      ctx.fillStyle = "#effcff";
      ctx.fill();
    }
    if (selected && (selected.id === edge.source || selected.id === edge.target)) {
      const midX = (a.x + b.x) / 2;
      const midY = (a.y + b.y) / 2;
      ctx.font = "9px system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = color;
      ctx.shadowColor = "#050a12";
      ctx.shadowBlur = 5;
      ctx.fillText(edge.relation.replaceAll("_", " "), midX, midY - 5);
    }
    ctx.restore();
  }

  function positionHud(point) {
    if (!selected) {
      recordHud.hidden = true;
      return;
    }
    recordHud.innerHTML = `<div class="hud-title">${escapeHTML(selected.title)}</div>`
      + `<div class="hud-meta">${escapeHTML(selected.type)} · ${escapeHTML(selected.status)}</div>`
      + `<div class="hud-excerpt">${escapeHTML(selected.excerpt || "No excerpt in export.")}</div>`;
    recordHud.hidden = false;
    const cardWidth = recordHud.offsetWidth || 250;
    const cardHeight = recordHud.offsetHeight || 92;
    let left = point.x > width * 0.62 ? point.x - cardWidth - 22 : point.x + 22;
    left = Math.max(12, Math.min(width - cardWidth - 12, left));
    const top = Math.max(74, Math.min(height - cardHeight - 72, point.y - cardHeight / 2));
    recordHud.style.left = `${left}px`;
    recordHud.style.top = `${top}px`;
    recordHud.dataset.anchorX = String(point.x < left ? left : left + cardWidth);
    recordHud.dataset.anchorY = String(top + Math.min(cardHeight - 12, Math.max(12, point.y - top)));
  }

  function drawHudConnector(point) {
    if (!selected || recordHud.hidden) return;
    const anchorX = Number(recordHud.dataset.anchorX);
    const anchorY = Number(recordHud.dataset.anchorY);
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(point.x, point.y);
    ctx.lineTo(anchorX, anchorY);
    ctx.strokeStyle = "#7ce9ff9c";
    ctx.lineWidth = 0.8;
    ctx.shadowColor = "#42d5ff";
    ctx.shadowBlur = 9;
    ctx.stroke();
    ctx.restore();
  }

  function draw(time = 0) {
    if (!ctx || !width || !height) return;
    ctx.clearRect(0, 0, width, height);
    const brainDrawn = brainRenderer && brainRenderer.draw(time);
    if (!brainDrawn) drawBrainFallback();
    drawOrbit(time);
    drawCortexLines();
    const shown = visible();
    const positions = new Map(shown.nodes.map((node) => [node.id, project(node.p)]));
    shown.edges.forEach((edge, index) => drawEdge(edge, index, positions, time));
    const ordered = [...shown.nodes].sort((a, b) => positions.get(b.id).z - positions.get(a.id).z);
    for (const node of ordered) {
      const point = positions.get(node.id);
      const radius = Math.max(4.6, 6.2 * point.scale);
      const isSelected = selected === node;
      const isHovered = hover === node;
      const glow = isSelected ? 22 : isHovered ? 15 : 10;
      const gradient = ctx.createRadialGradient(point.x - radius * 0.25, point.y - radius * 0.3, 0, point.x, point.y, radius + (isSelected ? 4 : 2));
      gradient.addColorStop(0, "#f5fdff");
      gradient.addColorStop(0.2, nodeColor(node));
      gradient.addColorStop(1, nodeColor(node) + "42");
      ctx.beginPath();
      ctx.arc(point.x, point.y, radius + (isSelected ? 3 : isHovered ? 1.5 : 0), 0, Math.PI * 2);
      ctx.fillStyle = gradient;
      ctx.globalAlpha = isSelected || isHovered ? 1 : 0.9;
      ctx.shadowColor = nodeColor(node);
      ctx.shadowBlur = glow;
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.globalAlpha = 1;
      ctx.lineWidth = isSelected ? 1.8 : 0.8;
      ctx.strokeStyle = isSelected ? "#f4fdff" : "#d8f3ff9c";
      ctx.stroke();

      const dx = point.x - width / 2;
      const dy = point.y - height / 2;
      const labelY = point.y + (Math.abs(dy) < 35 ? -radius - 9 : Math.sign(dy) * 10);
      const fontSize = Math.max(10, 10.5 * point.scale);
      ctx.font = `${isSelected ? "650" : "520"} ${fontSize}px system-ui, sans-serif`;
      const label = Core.labelPosition(point.x, width, ctx.measureText(node.title).width);
      ctx.textAlign = label.align;
      ctx.textBaseline = dy > 35 ? "top" : "alphabetic";
      ctx.fillStyle = isSelected ? "#ffffff" : "#d8e8f1";
      ctx.shadowColor = "#06101b";
      ctx.shadowBlur = 6;
      if (label.maxWidth === undefined) {
        ctx.fillText(node.title, label.x, Math.max(20, Math.min(height - 19, labelY)));
      } else {
        ctx.fillText(node.title, label.x, Math.max(20, Math.min(height - 19, labelY)), label.maxWidth);
      }
      ctx.shadowBlur = 0;
    }
    if (selected) {
      const point = positions.get(selected.id);
      positionHud(point);
      drawHudConnector(point);
    } else {
      recordHud.hidden = true;
    }
  }

  function updateCounts() {
    const current = visible();
    const projectName = data.meta?.project || "Local graph";
    counts.textContent = `${current.nodes.length} visible records · ${current.edges.length} typed relations · ${projectName}`;
  }

  function renderLegend() {
    const types = [...new Set(nodes.map((node) => node.type))];
    byId("legend").innerHTML = types.map((type) => {
      const color = nodeColor({ type });
      return `<span class="legend-item"><i class="dot" style="color:${color};background:${color}"></i>${escapeHTML(type)}</span>`;
    }).join("");
  }

  function renderDetails() {
    if (!selected) {
      details.innerHTML = '<div class="empty">Select a node to inspect its type, status, provenance and relations.</div>';
      relationBox.innerHTML = '<div class="empty">Select a record to see typed connections.</div>';
      return;
    }
    const node = selected;
    const layer = Core.recordLayer(node);
    details.innerHTML = `<div class="name">${escapeHTML(node.title)}</div>`
      + `<div class="kind">${escapeHTML(node.type)} · ${escapeHTML(node.status)} · ${escapeHTML(node.trust || "unspecified")}</div>`
      + `<div class="desc">${escapeHTML(node.excerpt || "No excerpt in export.")}</div>`
      + `<div class="row"><span>Canonical ref</span><b>${escapeHTML(node.id)}</b></div>`
      + `<div class="row"><span>Provenance</span><b>${escapeHTML(node.provenance || "Not present")}</b></div>`
      + `<div class="row"><span>Observed</span><b>${escapeHTML(node.generated || "Unknown")}</b></div>`
      + `<div class="row"><span>Record layer</span><b>${escapeHTML(layer)}</b></div>`;
    const current = visible();
    const records = new Map(current.nodes.map((item) => [item.id, item]));
    const attached = current.edges.filter((edge) => edge.source === node.id || edge.target === node.id);
    relationBox.innerHTML = attached.length ? attached.map((edge) => {
      const outbound = edge.source === node.id;
      const other = records.get(outbound ? edge.target : edge.source);
      if (!other) return "";
      const direction = outbound ? "Outbound" : "Inbound";
      return `<button type="button" class="rel" data-id="${escapeHTML(other.id)}">`
        + `<small>${direction} · ${escapeHTML(edge.relation)}</small>${escapeHTML(other.title)}</button>`;
    }).join("") : '<div class="empty">No visible indexed connections.</div>';
    relationBox.querySelectorAll(".rel").forEach((button) => {
      button.addEventListener("click", () => select(idMap.get(button.dataset.id) || null));
    });
  }

  function renderList() {
    const current = visible();
    listElement.innerHTML = current.nodes.map((node) => {
      const color = nodeColor(node);
      return `<button class="listitem" type="button" data-id="${escapeHTML(node.id)}" aria-label="Inspect ${escapeHTML(node.title)}">`
        + `<i class="dot" style="color:${color};background:${color}"></i><span class="list-title">${escapeHTML(node.title)}</span>`
        + `<small>${escapeHTML(node.type)} · ${escapeHTML(node.status)}</small></button>`;
    }).join("");
    listElement.querySelectorAll(".listitem").forEach((button) => {
      button.addEventListener("click", () => select(idMap.get(button.dataset.id) || null));
    });
  }

  function applyFilters() {
    const current = visible();
    if (selected && !current.nodes.some((node) => node.id === selected.id)) selected = null;
    updateCounts();
    renderDetails();
    renderList();
    draw();
  }

  function select(node) {
    const current = visible();
    selected = node && current.nodes.some((item) => item.id === node.id) ? node : null;
    renderDetails();
    renderList();
    draw();
  }

  function resetView() {
    camera.yaw = 0;
    camera.tilt = 0;
    camera.zoom = fitZoom;
    hover = null;
    select(null);
  }

  function resize() {
    const rect = canvas.getBoundingClientRect();
    width = rect.width;
    height = rect.height;
    pixelRatio = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.max(1, Math.round(width * pixelRatio));
    canvas.height = Math.max(1, Math.round(height * pixelRatio));
    ctx.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    brainRenderer?.resize();
    const nextFitZoom = Core.fitZoom(nodes, width, height, measureLabel);
    camera.zoom = hasSized ? Core.zoomForResize(camera.zoom, fitZoom, nextFitZoom) : nextFitZoom;
    fitZoom = nextFitZoom;
    hasSized = true;
    draw();
  }

  function hit(x, y) {
    return Core.nearestNode(visible().nodes, x, y, project, 20);
  }

  function updateMotionPreference() {
    prefersReducedMotion = Core.usesReducedMotion(reducedQuery);
    document.documentElement.classList.toggle("reduced-motion", prefersReducedMotion);
    byId("motionNote").textContent = prefersReducedMotion
      ? "Reduced motion is on · graph remains static until you interact."
      : "Ambient motion is subtle · use your system setting to reduce it.";
    if (prefersReducedMotion && animationFrame) {
      cancelAnimationFrame(animationFrame);
      animationFrame = 0;
      draw(performance.now());
    } else if (!prefersReducedMotion && !animationFrame) {
      animationFrame = requestAnimationFrame(animate);
    }
  }

  function animate(time) {
    animationFrame = 0;
    if (prefersReducedMotion) return;
    if (time - lastFrame > 45) {
      lastFrame = time;
      draw(time);
    }
    animationFrame = requestAnimationFrame(animate);
  }

  function clearSearchAndSelection() {
    search.value = "";
    filter.value = "all";
    selected = null;
    hover = null;
    applyFilters();
    search.focus();
  }

  function setListExpanded(expanded) {
    listElement.hidden = !expanded;
    listButton.setAttribute("aria-expanded", String(expanded));
    listButton.textContent = expanded ? "Hide list" : "List view";
  }

  canvas.addEventListener("pointerdown", (event) => {
    if (event.button !== undefined && event.button !== 0) return;
    try { canvas.setPointerCapture(event.pointerId); } catch { /* Browser may not support capture. */ }
    drag = { x: event.clientX, y: event.clientY, yaw: camera.yaw, tilt: camera.tilt, moved: false };
  });
  canvas.addEventListener("pointermove", (event) => {
    hover = hit(event.offsetX, event.offsetY);
    if (drag) {
      const dx = event.clientX - drag.x;
      const dy = event.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
      camera.yaw = drag.yaw + dx * 0.008;
      camera.tilt = Math.max(-1.15, Math.min(1.15, drag.tilt + dy * 0.006));
    }
    draw(performance.now());
  });
  function endPointer(event) {
    if (drag && !drag.moved && event.type !== "pointercancel") select(hit(event.offsetX, event.offsetY));
    drag = null;
  }
  canvas.addEventListener("pointerup", endPointer);
  canvas.addEventListener("pointercancel", endPointer);
  canvas.addEventListener("pointerleave", () => { if (!drag) { hover = null; draw(performance.now()); } });
  canvas.addEventListener("wheel", (event) => {
    event.preventDefault();
    camera.zoom = Core.zoomBy(camera.zoom, event.deltaY);
    draw(performance.now());
  }, { passive: false });
  canvas.addEventListener("keydown", (event) => {
    const step = event.shiftKey ? 0.22 : 0.1;
    if (event.key === "Escape") select(null);
    else if (event.key === "ArrowLeft") camera.yaw -= step;
    else if (event.key === "ArrowRight") camera.yaw += step;
    else if (event.key === "ArrowUp") camera.tilt = Math.min(1.15, camera.tilt + step);
    else if (event.key === "ArrowDown") camera.tilt = Math.max(-1.15, camera.tilt - step);
    else if (event.key === "+" || event.key === "=") camera.zoom = Core.clampZoom(camera.zoom * 1.12);
    else if (event.key === "-") camera.zoom = Core.clampZoom(camera.zoom / 1.12);
    else return;
    event.preventDefault();
    draw(performance.now());
  });
  search.addEventListener("input", applyFilters);
  filter.addEventListener("change", applyFilters);
  byId("clear").addEventListener("click", clearSearchAndSelection);
  byId("reset").addEventListener("click", resetView);
  byId("asideReset").addEventListener("click", resetView);
  byId("fit").addEventListener("click", resetView);
  byId("asideFit").addEventListener("click", resetView);
  listButton.addEventListener("click", () => setListExpanded(listElement.hidden));
  window.addEventListener("keydown", (event) => { if (event.key === "Escape") select(null); });
  window.addEventListener("resize", resize);
  brainCanvas.addEventListener("webglcontextlost", (event) => { event.preventDefault(); draw(performance.now()); });
  if (reducedQuery.addEventListener) reducedQuery.addEventListener("change", updateMotionPreference);
  else if (reducedQuery.addListener) reducedQuery.addListener(updateMotionPreference);

  const privacy = String(data.meta?.privacy || "").toLowerCase();
  if (privacy.includes("principal-filtered") && privacy.includes("snapshot")) sourceBadge.textContent = "Filtered · offline snapshot";
  else if (privacy.includes("principal-filtered")) sourceBadge.textContent = "Filtered · local session";
  else if (privacy.includes("synthetic")) sourceBadge.textContent = "Synthetic · offline";
  else sourceBadge.textContent = "Local projection";
  document.querySelector(".sub").textContent = privacy.includes("principal-filtered")
    ? "LLM-Brain filtered projection · read-only"
    : "LLM-Brain memory graph · local view";
  renderLegend();
  updateCounts();
  renderList();
  renderDetails();
  updateMotionPreference();
  resize();
})();
