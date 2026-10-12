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

    useEffect(function () {
      SDK.fetchJSON(API + "/status").then(setStatus).catch(function (e) { setError(String(e.message || e)); });
      SDK.fetchJSON(API + "/projects").then(function (r) { setProjects((r && r.projects) || []); }).catch(function () { setProjects([]); });
    }, []);

    function load(nextMode, chosen) {
      if (chosen === undefined) chosen = project;
      setMode(nextMode); setError(""); setHtml("");
      const query = nextMode === "export" && chosen ? "&project=" + encodeURIComponent(chosen) : "";
      SDK.fetchJSON(API + "/view?mode=" + encodeURIComponent(nextMode) + query)
        .then(function (r) { setHtml(r.html || ""); })
        .catch(function (e) { setError(String(e.message || e)); });
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
        }, [h("option", { key: "", value: "" }, "Detected project")].concat(projects.map(function (p) {
          return h("option", { key: p.project_id, value: p.project_id }, p.alias + " (" + p.records + " records, " + p.relations + " relations, " + p.pending_review + " pending)");
        }))) : null,
        h("span", { style: { opacity: 0.7 } }, mode === "demo" ? "Synthetic data only." : "Principal-filtered local snapshot with label lineage."),
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
