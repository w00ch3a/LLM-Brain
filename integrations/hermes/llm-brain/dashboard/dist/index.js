/**
 * LLM-Brain — Neural Expansion dashboard page.
 *
 * Plain IIFE, no build step. Loads the page from the plugin backend
 * (/api/plugins/llm-brain/view) into a sandboxed iframe: scripts run, but
 * there is no same-origin access and the page itself has no network access.
 */
(function () {
  "use strict";
  const SDK = window.__HERMES_PLUGIN_SDK__;
  if (!SDK) return;
  const { React } = SDK;
  const h = React.createElement;
  const { useState, useEffect } = SDK.hooks;
  const { Button, Card, CardContent } = SDK.components;
  const API = "/api/plugins/llm-brain";

  function NeuralExpansionPage() {
    const [status, setStatus] = useState(null);
    const [mode, setMode] = useState("demo");
    const [html, setHtml] = useState("");
    const [error, setError] = useState("");
    const [projects, setProjects] = useState([]);
    const [project, setProject] = useState("");
    const [progress, setProgress] = useState("");
    const token = SDK.hooks.useRef ? SDK.hooks.useRef(0) : React.useRef(0);
    useEffect(function () { return function () { token.current += 1; }; }, []);

    function loadAll(mine) {
      setProgress("Loading all projects\u2026");
      function fail(e) { if (token.current === mine) { setProgress(""); setError(String(e.message || e)); } }
      SDK.fetchJSON(API + "/view-all/start").then(function (started) {
        function poll() {
          if (token.current !== mine) return;
          SDK.fetchJSON(API + "/view-all/status?job=" + encodeURIComponent(started.job)).then(function (r) {
            if (token.current !== mine) return;
            if (r && r.status === "ok") {
              setProgress(r.skipped ? (r.total - r.skipped) + " of " + r.total + " projects loaded (" + r.skipped + " skipped)" : "");
              setHtml(r.html || "");
            } else {
              setProgress("Loading all projects\u2026 " + ((r && r.done) || 0) + "/" + ((r && r.total) || started.total) + (r && r.skipped ? " (" + r.skipped + " skipped)" : ""));
              setTimeout(poll, 1200);
            }
          }).catch(fail);
        }
        poll();
      }).catch(fail);
    }

    useEffect(function () {
      SDK.fetchJSON(API + "/status").then(setStatus).catch(function (e) { setError(String(e.message || e)); });
      SDK.fetchJSON(API + "/projects").then(function (r) { setProjects((r && r.projects) || []); }).catch(function () { setProjects([]); });
    }, []);

    function load(nextMode, chosen) {
      if (chosen === undefined) chosen = project;
      const mine = ++token.current;
      setMode(nextMode); setError(""); setHtml(""); setProgress("");
      if (nextMode === "export" && chosen === "__all__") { loadAll(mine); return; }
      const query = nextMode === "export" && chosen ? "&project=" + encodeURIComponent(chosen) : "";
      SDK.fetchJSON(API + "/view?mode=" + encodeURIComponent(nextMode) + query)
        .then(function (r) { if (token.current === mine) setHtml(r.html || ""); })
        .catch(function (e) { if (token.current === mine) setError(String(e.message || e)); });
    }

    const exportEnabled = status && status.export_enabled;
    return h("div", { className: "llm-brain-neural-expansion", style: { display: "flex", flexDirection: "column", gap: "12px", height: "100%" } },
      h(Card, null, h(CardContent, { style: { display: "flex", gap: "8px", alignItems: "center", flexWrap: "wrap", paddingTop: "12px" } },
        h("strong", null, "Neural Expansion"),
        h(Button, { onClick: function () { load("demo"); } }, "Synthetic demo"),
        h(Button, { onClick: function () { load("export"); }, disabled: !exportEnabled,
          title: exportEnabled ? "This profile's brain, principal-filtered, read-only" : "Set \"neural_expansion_export\": true in llm-brain.json" }, "My brain"),
        exportEnabled && projects.length ? h("select", {
          value: project, title: "Project (records / relations / pending review)",
          onChange: function (e) { setProject(e.target.value); load("export", e.target.value); }
        }, [h("option", { key: "", value: "" }, "Detected project"),
          h("option", { key: "__all__", value: "__all__" }, "View all (All projects: " + projects.reduce(function (n, p) { return n + p.records; }, 0) + " records, " + projects.reduce(function (n, p) { return n + p.pending_review; }, 0) + " pending)")].concat(projects.map(function (p) {
          return h("option", { key: p.project_id, value: p.project_id }, p.alias + " (" + p.records + " records, " + p.relations + " relations, " + p.pending_review + " pending)");
        }))) : null,
        h("span", { style: { opacity: 0.7 } }, mode === "demo" ? "Synthetic data only." : "Principal-filtered local snapshot with label lineage."),
        progress ? h("span", { role: "status", style: { opacity: 0.85 } }, progress) : null,
        error ? h("span", { style: { color: "#d66" } }, error) : null
      )),
      html ? h("iframe", { title: "Neural Expansion", sandbox: "allow-scripts", srcDoc: html,
        style: { flex: 1, minHeight: "70vh", width: "100%", border: "0", borderRadius: "8px" } }) : null
    );
  }

  if (window.__HERMES_PLUGINS__ && typeof window.__HERMES_PLUGINS__.register === "function") {
    window.__HERMES_PLUGINS__.register("llm-brain", NeuralExpansionPage);
  }
})();
