# SwiftyDebug

An in-app debugging tool for iOS. Shake your device to inspect every network request, read your logs, browse the app container, and **change traffic on the fly** — mock a response, pause a request mid-flight and edit it, or rewrite values in every response automatically.

No external dependencies. UIKit. iOS 15+.

```swift
SwiftyDebug.monitorAllUrls = true
SwiftyDebug.enable()
```

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Opening the debugger](#opening-the-debugger)
- [Features](#features)
  - [Network capture](#network-capture)
  - [Inspecting a request](#inspecting-a-request)
  - [Search](#search)
  - [Changing traffic](#changing-traffic)
  - [Replay and cURL](#replay-and-curl)
  - [WebView support](#webview-support)
  - [Logs](#logs)
  - [Media](#media)
  - [App inspectors](#app-inspectors)
  - [The JSON editor](#the-json-editor)
- [Public API](#public-api)
- [Things to know before you integrate](#things-to-know-before-you-integrate)
- [Security](#security)
- [Demo app](#demo-app)
- [License](#license)

---

## Requirements

| | |
|---|---|
| **iOS** | 15.0+ |
| **Swift** | 5.9 |
| **UI framework** | UIKit. The overlay attaches to the first available `UIWindowScene`, so it works over a SwiftUI app, but every screen inside is UIKit. |
| **Dependencies** | None. Links the system `sqlite3`. |

---

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/oah2008/SwiftyDebug.git", from: "0.7.0")
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

### CocoaPods

```ruby
pod 'SwiftyDebug', '~> 0.7', :configurations => ['Debug']
```

The `:configurations => ['Debug']` is not optional advice — see [Security](#security).

---

## Quick start

```swift
import SwiftyDebug

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

    #if DEBUG
    SwiftyDebug.monitorAllUrls = true      // capture everything
    SwiftyDebug.monitorMedia   = false     // skip images/video/audio/fonts
    SwiftyDebug.enableConsoleLog = true

    SwiftyDebug.addTag(keyword: "algolia", label: "Search")
    SwiftyDebug.addTag(keyword: "stripe",  label: "Payments")

    SwiftyDebug.enable()
    #endif

    return true
}
```

To capture only certain hosts, leave `monitorAllUrls` off and list them:

```swift
SwiftyDebug.urls = ["api.myapp.com", "cdn.myapp.com"]
```

`urls` is a case-insensitive substring match. **If `urls` is empty and `monitorAllUrls` is false, everything is still captured** — an empty list is not a filter.

> **Call `enable()` and `disable()` on the main thread.** `enable()` synchronously creates a `UIWindow`.

---

## Opening the debugger

**Shake the device** to show or hide the floating bubble. **Tap the bubble** to open the debugger.

The bubble also:
- shows a live request counter and flashes each request's status as it completes
- **long-press** clears all captured requests (pinned ones survive)
- **drag** to move it; it snaps to the nearest edge

Inside are four tabs: **Network**, **Logs**, **Media**, **App**.

Touches pass straight through to your app everywhere except the bubble itself, so the app stays usable underneath.

---

## Features

### Network capture

Requests are captured by a `URLProtocol` subclass, installed by swizzling `URLSessionConfiguration`'s default and ephemeral constructors plus its `protocolClasses` getter — so sessions built from configurations created *before* the SDK started are captured too.

Captured for each request: URL, method, headers, request and response bodies, status, timing, and error.

**What is not captured:**

| | |
|---|---|
| Schemes other than `http`/`https` | WebSockets, `file://`, and anything not going through URLSession |
| Background sessions | iOS does not run custom `URLProtocol`s for `background(withIdentifier:)` |
| WebView page loads | Only XHR and `fetch` — see [WebView support](#webview-support) |

Bodies are stored on disk, not in memory. Capture is truncated at **10 MB** for responses and **512 KB** for request bodies — **your app always receives the full, unmodified bytes**; only the debugger's copy is trimmed, and the request is flagged as truncated.

### Inspecting a request

The **Network** tab has three lists — **App**, **Web**, **Pinned** — each keeping its own search text, filters, grouping and scroll position.

Rows show the method, a host or tag pill, the URL, content type, size, duration and timestamp, colour-coded by status (2xx green, 3xx orange, 4xx/5xx red) and by duration.

Tap a request for the detail screen: **URL**, query parameters, request and response headers, request body, response body, **cURL**, timing breakdown, decoded **JWT** claims, error details, and cache info. Any section can be copied; the whole request exports as JSON or a shareable file.

Requests can be **pinned** to survive a clear and an app restart.

### Search

Typing searches an index built once at capture time — URL, host, path, method, status, headers and query params — so it never touches the disk and stays instant. Field-scoped queries work too:

```
header:authorization    status:500    method:POST
host:api.example.com    param:page    path:/users    type:json
```

**Advanced** opens a sheet of described toggles for the searches that cost more:

| Toggle | What it does |
|---|---|
| **Response body** | Also search what the server sent back |
| **Request body** | Also search what your app sent |
| **Case sensitive** | Off, `Token` also finds `token` |
| **Scan whole bodies** | By default only the first 2 MB of each body is read |
| **Include media** | Images, video and audio are skipped by default |

Body matches merge into the same list with the matching snippet underneath and a `REQUEST`/`RESPONSE` badge.

### Changing traffic

Everything below hangs off an **intercept rule**. Create one from a request's detail screen (**Intercept**) or from the App tab.

A rule has a **scope**:

| Scope | Matches |
|---|---|
| **Pattern** | The path with IDs and UUIDs normalised — `/users/123/orders` also matches `/users/456/orders` |
| **Exact** | One literal path |
| **Host** | A URL prefix — `api.example.com/v1` matches `/v1/**` but not `/v2/**` |
| **Global** | Every request |

All *enabled* matching rules merge into one composite per request.

> **Pattern and Exact match on the path only** — the host is not checked, so `/api/users` matches that path on every host. Use Host scope to pin it down.

#### Headers and query parameters

Set or remove either. Each row has a checkbox and **only checked rows apply** — an unchecked row is editor state and changes nothing. Section headers show `(N of M active)`.

A new endpoint-scoped rule arrives pre-filled with that request's real headers and params, already checked. Header and param names seen in real traffic are offered as suggestions and survive clearing the request list.

#### Block

Fails the request immediately without sending it.

#### Redirect

**Host only** replaces the host (and optional port), keeping scheme, path and query.
**Host and path** replaces both, still keeping the original query string.

```
webapp.com/checkout/abc?p=1  +  beta.webapp.com
    → beta.webapp.com/checkout/abc?p=1
```

A live before/after preview runs the real redirect code. Any query or fragment typed into the target is discarded — the original request's query always wins. The `Host` header is rewritten to match unless your rule overrides it explicitly.

#### Mock responses

Return a canned response without touching the network. Pick from **14 scenario presets** (200, 201, 204, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503, "Empty list"), set the status, edit the body in the JSON editor (or start from the real response), and add a delay of up to 10 s.

`Content-Length` is always recomputed from the body. Mocked requests appear in the list like real ones.

#### Breakpoints

Pause a matching request **before send** or **after response** — one stage per rule, so a request is never stopped twice. Nothing blocks a thread; the request parks a continuation.

Held requests appear in the **paused inbox**, reachable from a `⏸ N` badge in the Network tab, from the App tab, or from a floating banner over your app that is one tap away. Each row shows a live "held for Ns" timer.

For an **after response** breakpoint you can open the body in the full JSON editor and then **Deliver to app**. The delivered response has its `Content-Length` corrected and stale `Content-Encoding`/`Transfer-Encoding` stripped. Binary bodies are passed through byte-for-byte and never re-encoded. An untouched body is delivered identically to the streamed path.

> **A before-send breakpoint is pause-and-release, not pause-and-edit.** The request is shown read-only; you can only send or abort it.

Because a held request delivers no bytes, your app's idle timeout would normally kill it. SwiftyDebug raises request timeouts to cover the hold — see [Things to know](#things-to-know-before-you-integrate). If the app gives up anyway, the row expires out of the inbox rather than offering a Deliver button that would do nothing.

#### Response rewrite rules

The edit you'd make by hand at a breakpoint, applied automatically to every matching response, with no pause.

```
{"data":{"url":"https://google.com/path/to/a"}}
                ↓   data.url  ·  Change host → webapp.com
{"data":{"url":"https://webapp.com/path/to/a"}}
```

**Path patterns:**

| Pattern | Matches |
|---|---|
| `data.url` | Exactly that value |
| `data.items[*].url` | Every element of the array |
| `data.items[0].url` | One index |
| `data.*.url` | Any key one level down |
| `**.url` | A key named `url` at any depth |
| `data["a.b"].url` | A key containing `.`, `[`, `]` or `*` |

**Five actions:** replace host · replace host and path · set a fixed value · find and replace (literal or regex) · remove the field.

The editor previews against a **real captured response** using the same engine that runs on the wire, shows scope choices with live match counts (*"Every "url" anywhere (14 values)"*), and lists up to 12 before/after pairs. A rewrite that matches nothing says so and needs confirming before it can be saved.

Types are preserved — a number stays a number. A non-URL value under "replace host" is reported and left alone rather than half-rewritten.

**A rewritten response is always marked.** Its section title becomes `RESPONSE · ✎ REWRITTEN`, and an info block lists every rewrite that ran with `matched N, changed N` — *including ones that matched nothing*. Your app is showing data the server never sent, and that is never hidden from you.

Interactions, all deliberate:

- **A mock beats a rewrite.** A mock never reaches the network, so rewrites never see it. The rule editor warns you, and the request records why it was skipped.
- **Rewrites run before an after-response breakpoint**, so the paused editor shows the already-rewritten body and manual edits compose on top.
- **WebView traffic is not rewritten.** The engine lives in the URLProtocol.
- Bodies over **2 MB** are skipped, with the reason recorded.

Rewrites are authored from the rule editor's **RESPONSE REWRITES** section.

#### Network link conditioner

Fixed latency presets on the App tab: Wi-Fi (1 ms), DSL (10 ms), LTE (50 ms), 3G (100 ms), Edge (400 ms), High Latency DNS (220 ms), Very Bad Network (500 ms), and 100% Loss. Latency and failure only — no bandwidth shaping.

### Replay and cURL

**Replay** re-runs a captured request after editing the method, URL, query parameters, headers and body. The result opens in the normal detail screen.

**Import cURL** pastes a command and opens it in the same replay editor. Repeated headers are preserved, curl's default `Content-Type` is supplied for a body that declares none, and a binary body is sent as its original bytes rather than re-encoded. Flags the parser understood but dropped are listed on screen.

**Export cURL** from any request, and **export/import intercept rules** as JSON to share a setup with a teammate.

### WebView support

`WKWebView` traffic can't go through `URLProtocol`, so SwiftyDebug injects a script that hooks `XMLHttpRequest` and `fetch`. Those requests appear in the Network tab's **Web** list.

Intercept rules apply to web view traffic for **block, header and query-param edits, and redirects**. Mocks, breakpoints and response rewrites do not — they live in the URLProtocol.

`User-Agent` and `Cookie` can't be set from JavaScript, so they're applied natively via `customUserAgent` and `WKHTTPCookieStore` (host and global scopes only). Other fetch-spec forbidden headers are best-effort.

Only web views created after `enable()` are hooked. Bodies are truncated at 512 KB; `FormData`, `Blob` and `ArrayBuffer` bodies are recorded as `null`.

**WebView storage** is browsable and editable from the App tab — localStorage, sessionStorage and cookies, with view, edit, add and delete. Values that are JSON open in the tree editor.

### Logs

The **Logs** tab captures:

- `print()` — importing SwiftyDebug overrides it, adding file, line and function, and an optional colour. Output still reaches Xcode unchanged.
- `NSLog` and OSLog, via a stdout pipe and an adaptive poll that backs off when idle and pauses in the background. Only stdout is redirected; stderr is untouched.
- WebView console output.

Logs are filterable and searchable by level, source and text, and are stored in SQLite with WAL journaling.

> **"Console Logs" is off by default.** Turn it on from the App tab.

### Media

Images, video, audio and fonts are routed out of the Network tab into their own **Media** tab and shown as a gallery. Media detection uses MIME type plus path extension, and images referenced inside JSON bodies are found by key name too (`image`, `thumbnail`, `avatar`, `logo`, …).

Tap for full-screen preview with metadata, and a link back to the request the image came from.

Set `SwiftyDebug.monitorMedia = true` to capture media at all — it's off by default.

### App inspectors

On the **App** tab:

| Inspector | What it does |
|---|---|
| **Web View Storage** | localStorage, sessionStorage and cookies — view, edit, add, delete |
| **App Container Files** | Browse the app container from `NSHomeDirectory()`, preview file contents |
| **User Defaults** | Your app's own defaults — view and edit, with type handling |
| **Keychain** | Passwords, certificates, keys and identities; passwords are editable |
| **Timeline** | Requests laid out over time |
| **Insights** | Aggregate stats over captured traffic |
| **Auth Tokens** | Tokens found in live traffic, with decoded JWT claims |
| **Paused Requests** | The breakpoint inbox |
| **Share Rules** | Export or import intercept rules as JSON |

User Defaults and Keychain read the **host app's** own storage, not SwiftyDebug's.

### The JSON editor

Used wherever a payload is edited — mock bodies, breakpoint responses, storage values, replay bodies.

- **Tree mode** — add, rename, retype, reorder, duplicate and delete nodes; arrays of objects get a template built from their siblings' keys
- **Raw mode** — edit or paste JSON as text, with live validation
- **Undo/redo** on every mutation
- Short values edit inline in a field that grows as you type; long ones open on their own full-height page

Any screen with a JSON payload shows a card reading *"Valid JSON · 12 keys"* that opens the tree editor.

---

## Public API

The entire public surface:

```swift
// Capture scope
SwiftyDebug.urls: [String]                  // case-insensitive substring match
SwiftyDebug.monitorAllUrls: Bool            // default false
SwiftyDebug.monitorMedia: Bool              // default false
SwiftyDebug.enableConsoleLog: Bool          // default true

// Raises host-app request timeouts so paused requests survive. Default FALSE.
SwiftyDebug.extendTimeoutsForBreakpoints: Bool
SwiftyDebug.extendTimeoutsChangeEffect: TimeoutChangeEffect          // preview, changes nothing
SwiftyDebug.setExtendTimeoutsForBreakpoints(_:) -> TimeoutChangeEffect

// Tags — a URL substring becomes a labelled pill in the list
SwiftyDebug.addTag(keyword: String, label: String)
SwiftyDebug.removeTag(keyword: String)
SwiftyDebug.removeAllTags()

// Lifecycle — main thread only
SwiftyDebug.enable()
SwiftyDebug.disable()

// The bubble window, if you need to drive it yourself
DebugWindowPresenter.shared.enable()
DebugWindowPresenter.shared.disable()

// Overrides Swift.print in any file that imports SwiftyDebug
print(_ message: T, color: UIColor = .white)
```

`networkTagMap` still exists but is deprecated; use `addTag(keyword:label:)`.

---

## Things to know before you integrate

**Request timeouts are left alone unless you opt in.** A request paused at a breakpoint delivers no bytes, so your app's own idle timeout would kill it before you could edit it. Turning on **Extend Request Timeouts** (App tab, or `SwiftyDebug.extendTimeoutsForBreakpoints = true`) raises request timeouts app-wide to the hold budget — ~10 minutes, for *every* request, not just paused ones — so retry ladders, watchdogs and "poor connection" banners stop firing while it's on. It is **off by default**; the SDK never touches your timeouts until you ask.

`URLSession` copies its configuration at init, so sessions your app has already built keep their old timeout either way. Use `SwiftyDebug.setExtendTimeoutsForBreakpoints(_:)`, which returns a `TimeoutChangeEffect` telling you whether a relaunch is needed; the App tab toggle prompts you automatically.

**`monitorAllUrls` and `monitorMedia` set before `enable()` are overwritten** by the persisted values of the App tab toggles from the previous launch. Set them from the App tab, or reassign after `enable()`.

**The "Network Requests" toggle only hides the list.** Capture continues. To actually stop, shake with **Full Stop on Disable** on.

**`disable()` is a partial stop.** It hides the overlay, unregisters the URLProtocol and mutes `print` capture, but leaves OSLog polling, WebView capture and installed swizzles running. The complete stop is the shake gesture with **Full Stop on Disable** enabled, which flips an atomic kill switch, releases held requests, tears down the log hooks and disables WebView capture. A handful of one-way swizzles stay installed and pass straight through.

**Captured requests are never evicted.** The list grows for the lifetime of the process until you clear it. Bodies live under `Caches`, so iOS may purge them under storage pressure.

**The debug UI is always left-to-right**, even inside an RTL host app. Your app is unaffected.

---

## Security

SwiftyDebug is a debug-only tool. **Do not ship it in a release build.**

It can read — and in several cases write:

- Your **Keychain** items, including passwords
- Your **UserDefaults**
- Your **entire app container**
- **WebView storage** and cookies
- Every request and response body, including `Authorization` headers

It also swizzles `URLSessionConfiguration`, `WKWebView` and `WKUserContentController` process-wide, and redirects `stdout`.

Gate it with `#if DEBUG` and, for CocoaPods, `:configurations => ['Debug']`.

A privacy manifest (`PrivacyInfo.xcprivacy`) declares required-reason API use for disk space, boot time and file timestamps. No data is collected and no network calls are made by the SDK itself.

---

## Demo app

```bash
cd Demo
pod install
open SwiftyDebugDemo.xcworkspace   # the workspace, not the project
```

The demo consumes the **local** pod (`:path => '../'`), so changes to `Sources/` show up without publishing. Adding a new file means re-running `pod install`.

It exercises a Pokémon list/detail flow, a JSONPlaceholder feed, and a WKWebView browser screen for testing webview capture.

---

## License

MIT. See [LICENSE](LICENSE).
