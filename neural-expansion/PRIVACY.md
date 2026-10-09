# Neural Expansion privacy boundary

Neural Expansion only shows data that has already been filtered. Canonical
Markdown stays in OKF. Indexes, snapshot packages and viewer projections are
derived and disposable.

## What ships

- The bundled demo and all test fixtures are synthetic. No real vault content,
  screenshots or generated pages from a real vault are included.
- The viewer page has no write operation and makes no network calls
  (`connect-src 'none'`). It loads no external scripts, fonts or images, and
  it never accepts a graph path, principal or project from the URL.
- Record text is escaped before it reaches the DOM.

## Rules for real data

1. Never point a static server at a vault, an OKF tree, a snapshot package, an
   unfiltered graph or a `knowledge-catalog` export.
2. Filter before serialising. The projection is built only from records that
   are effective and visible to the selected principal. Edges need two visible
   canonical endpoints, and hidden labels, hashes and counts are omitted.
3. `--principal` is a visibility selector, not authentication. A real
   multi-user or browser-session integration needs an authenticated host that
   maps a verified subject to a principal server-side. It must never take
   identity, project, path or generation from the browser.
   `adapter/session_bridge.py` defines that seam. It is not wired to any host.
4. Keep exports private: they are new owner-only (`0600`) files outside the
   vault. Do not sync, publish or share them. If your vault lives on network
   storage, write exports to a private location on that same storage.
5. Any local serving of the synthetic demo must bind to loopback only, for
   example `python3 -m http.server 8765 --bind localhost --directory neural-expansion/demo`.
6. Treat browser caches as persistent. Only load real data in a browser
   profile whose storage you control.

## Known limits

- The one-shot export checks for active writers and transitions before and
  after packaging, but does not hold the project lock. Index and document
  hashes catch mixed generations; rerun after a conflict.
- The export stages its private package in the system temporary directory
  (mode `0700`, removed afterwards).
- Touch interaction and the forced Canvas2D fallback have not been
  browser-verified.
