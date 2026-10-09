# Neural Expansion

Neural Expansion is LLM-Brain's read-only, offline memory-graph viewer. It
renders records and their typed relations as an interactive graph, with a
detail panel, search, status filters and a keyboard-accessible list view.

It is a viewer, not a memory store. It has no write controls, network calls,
telemetry, external assets or runtime dependencies. Each page is a single
self-contained HTML file. The page's content policy blocks all network
connections.

## Quick start (synthetic demo)

```sh
llm-brain neural-expansion demo --open        # open the bundled synthetic demo
llm-brain neural-expansion path               # print the demo file's path
llm-brain neural-expansion demo --output ./ne-demo.html   # rebuild a copy
```

`llm-brain viewer ...` is an alias. The bundled page
`demo/neural-expansion-synthetic.html` contains only the synthetic fixture
`fixtures/synthetic.json`, and it shows a visible
`NEURAL EXPANSION · SYNTHETIC DEMO · OFFLINE` banner. After editing
`index.html`, `viewer.js` or `neural-core.js`, rebuild it:

```sh
python3 neural-expansion/build_demo.py
```

## Interaction

- Drag the graph to orbit and scroll to zoom; zoom is bounded.
- Click a node to see its record, provenance and visible typed relations.
- Search by title, ID, type, status, provenance or excerpt, and filter by
  status. Counts, nodes, edges, list entries and details all come from the
  same visible set.
- **List view** gives keyboard access. On the canvas, the arrow keys orbit,
  `+`/`-` zoom and `Esc` clears the selection. **Fit graph** and **Reset**
  return to the fitted view.
- The viewer honours `prefers-reduced-motion` and falls back from WebGL to a
  Canvas2D wireframe.

## Your own vault (experimental)

```sh
llm-brain index build PROJECT_ID
LLM_BRAIN_NEURAL_EXPANSION_EXPORT=1 \
  llm-brain neural-expansion export PROJECT_ID --principal ID --output /private/dir/brain.html
```

The export does the following:

1. It packages the current index generation (`documents.tsv`, `graph.tsv`,
   `manifest.tsv`, the matching Markdown and retraction inputs) into a private
   temporary directory and verifies its hashes.
2. It applies OKF lifecycle and principal/audience visibility filtering before
   serialisation. Hidden records, their labels, hashes and incident edges are
   dropped. An edge is kept only when both endpoints are visible.
3. It writes one new owner-only (`0600`) HTML file outside the vault.

It refuses to run while a project writer or vault transition is active. It
does not hold the project lock, so it can race with a writer that starts
mid-export; rerun it if that happens. **`--principal` is a visibility filter,
not authentication.** Do not share the file, serve it, or put it in a
synced or static-server directory. Read [PRIVACY.md](PRIVACY.md) first.

## Layout

| Path | Purpose |
|---|---|
| `index.html`, `viewer.js`, `neural-core.js` | Viewer source (no build step, no dependencies) |
| `build_demo.py` | Inlines the source and the synthetic fixture into one HTML file |
| `fixtures/synthetic.json` | Synthetic OKF-shaped graph used by the demo and tests |
| `demo/neural-expansion-synthetic.html` | Generated synthetic demo (checked against the builder by tests) |
| `adapter/snapshot_producer.py` | Packages one index generation (read-only) |
| `adapter/export_graph.py` | Principal-filters a package into a viewer projection |
| `adapter/snapshot_to_html.py` | One-shot private HTML export used by the CLI |
| `adapter/session_bridge.py` | Integration seam for a future authenticated host (not wired) |
| `bench.py` | Synthetic graph-preparation benchmark |
| `tests/` | Synthetic adapter, demo and viewer-logic tests |

The adapters use the Python standard library plus the PyYAML version that
LLM-Brain already pins (`requirements-okf.lock`).

## Checks

```sh
python3 -m unittest discover -s neural-expansion/tests
node --test neural-expansion/tests/viewer_logic.test.cjs   # optional; skipped when Node is absent
bash tests/neural-expansion-self-check.sh                  # part of the release gate
```

All fixtures are synthetic and created in temporary directories.
