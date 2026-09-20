# Vendored third-party code

## `andypf-json-viewer.js`

The renderer behind the full-screen JSON viewer
(`JSONViewerViewController` in `Sources/UI/NetworkDetailViewController.swift`).

* Upstream: <https://github.com/andypf/json-viewer>
* Fetched from: `https://pfau-software.de/json-viewer/dist/iife/index.js`
* Build: the IIFE bundle, unmodified — the MIT licence text is the first thing
  in the file.
* Licence: MIT, © 2025 Andreas Pfau.

### Why it is vendored rather than linked

The viewer used to load that URL at runtime, inside a `WKWebView` running in
the **host app's** process. That meant:

* **No offline viewer.** The script did not load on a plane, on a captive
  network or behind a proxy — which is exactly where people debug. The page
  still finished loading, so `<andypf-json-viewer>` stayed an unknown element,
  the body silently never rendered, and the user saw a dark screen showing
  `{}` with no error and no retry.
* **An unreviewed code path into production apps.** The URL carries no version
  and no integrity hash, so whatever that host served was executed by every app
  embedding this SDK, with no commit, no review and no diff.

A pinned local copy removes both. To update it, replace the file, re-run the
viewer against a large body, and note the new upstream version here.
