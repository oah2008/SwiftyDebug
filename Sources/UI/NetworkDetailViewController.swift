//
//  NetworkDetailViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

class NetworkDetailViewController: UITableViewController {
    
    private var closeItem: UIBarButtonItem!
    private var pinItem: UIBarButtonItem!

    var naviItemTitleLabel: UILabel?
    
    var httpModel: NetworkTransaction?
    var httpModels: [NetworkTransaction]?

    /// When true this screen is showing the **result of a replay**. The layout is
    /// identical to a normal request detail — same sections, same close/pin/share
    /// buttons — except the Intercept and Replay actions are hidden. (See REPLAY.)
    var isReplayResult = false
    
    var detailModels: [NetworkDetailSection] = [NetworkDetailSection]()

    /// Raw cURL string — stored separately because NetworkDetailSection.init
    /// applies replacingOccurrences(of: "\\/", with: "/") which corrupts
    /// JSON body data inside the cURL command.
    private var rawCurlString: String = ""

    // MARK: - Response rewrite entry point (see RESPONSE-REWRITE)

    /// Title of the marker section that renders the "Rewrite a value…" card.
    /// The card carries no text of its own in the model, so it never leaks into
    /// the shared/copied details text.
    private static let rewriteActionTitle = "AUTOMATE THIS RESPONSE"

    /// The response bytes, read from disk ONCE in `setupModels`.
    /// `httpModel.responseData` hits the disk on every access, so the rewrite
    /// flow reuses this and never re-reads — least of all from `cellForRowAt`.
    /// Released in `viewWillDisappear` with the rest of the big strings.
    private var cachedResponseBody: Data?

    /// Whether the rewrite card can do anything, decided once at setup.
    private enum RewriteEntryState {
        /// Nothing worth saying — no body, an image, or a replay result.
        case hidden
        /// Tappable: JSON, within the engine's size cap, with a URL to scope a rule to.
        case ready
        /// Shown but inert, carrying the reason in words. A control that is
        /// visible and silently does nothing is the thing this avoids.
        case blocked(String)

        var isHidden: Bool {
            if case .hidden = self { return true }
            return false
        }
    }

    /// Computed in `setupModels` from the single response parse — never derived
    /// in `cellForRowAt`.
    private var rewriteEntryState: RewriteEntryState = .hidden

    var headerCell: NetworkCell?
    
    var messageBody: String {
        return buildMessageBody()
    }
    
    var justCancelCallback:(() -> Void)?
    
    //MARK: - tool
    func setupModels() {
        guard let requestSerializer = httpModel?.requestSerializer else { return }
        var requestContent: String? = nil

        // Load data from disk ONCE into local variables.
        // Each access to .requestData / .responseData reads from disk,
        // so we must not call the getter multiple times.
        let cachedRequestData: Data? = httpModel?.requestData  // single disk read
        // responseData loaded later, only when needed

        // detect the request parameter format (JSON/Form)
        if requestSerializer == RequestSerializer.json {
            requestContent = cachedRequestData?.dataToPrettyPrintString()
        }else if requestSerializer == RequestSerializer.form {
            if let data = cachedRequestData {
                // 1. Try UTF-8 string
                var rawString = String(data: data, encoding: .utf8) ?? ""
                if rawString.isEmpty {
                    rawString = data.dataToString() ?? ""
                }

                // 2. Handle application/x-www-form-urlencoded
                if rawString.contains("=") && !rawString.contains("Content-Disposition: form-data;") {
                    // Kept as ordered pairs, not a dictionary: the wire order is
                    // the order the app sent these fields in, and a dictionary
                    // rendered them in hash order. (See OrderedJSON.)
                    var fields: [(key: String, value: String)] = []
                    let pairs = rawString.components(separatedBy: "&")
                    for pair in pairs {
                        let parts = pair.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let key = parts[0].removingPercentEncoding ?? parts[0]
                            let value = parts[1...].joined(separator: "=").removingPercentEncoding ?? ""
                            fields.append((key: key, value: value))
                        }
                    }
                    requestContent = OrderedJSON.text(from: fields) ?? rawString
                }
                // 3. Handle multipart/form-data
                else if rawString.contains("Content-Disposition: form-data;") {
                    // Same reason as above: parts arrive in a defined order and
                    // are shown in it.
                    var formFields: [(key: String, value: String)] = []
                    let boundaryParts = rawString.components(separatedBy: "--").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    for part in boundaryParts {
                        if let nameRange = part.range(of: "name=\""),
                           let endRange = part[nameRange.upperBound...].range(of: "\"") {
                            let name = String(part[nameRange.upperBound..<endRange.lowerBound])
                            let sections = part.components(separatedBy: "\r\n\r\n")
                            if sections.count > 1 {
                                let value = sections[1].replacingOccurrences(of: "\r\n", with: "")
                                if !value.isEmpty {
                                    formFields.append((key: name, value: value))
                                }
                            }
                        }
                    }
                    requestContent = OrderedJSON.text(from: formFields) ?? rawString
                }
                // 4. Fallback
                else {
                    requestContent = rawString.isEmpty ? nil : rawString
                }

                if requestContent == "" || requestContent == "\u{8}\u{1e}" {
                    requestContent = nil
                }
            }
        }

        // Load response data from disk ONCE - single disk read
        let cachedResponseData: Data? = httpModel?.responseData

        let urlStr = httpModel?.url?.absoluteString

        // URL (hidden row placeholder)
        let model_1 = NetworkDetailSection(title: "URL", content: "https://github.com/SwiftyDebug/SwiftyDebug", url: urlStr, httpModel: httpModel)

        // Request parameters (extracted from URL query string)
        var modelParams = NetworkDetailSection(title: "REQUEST PARAMETERS", content: nil, url: urlStr, httpModel: httpModel)
        if let url = httpModel?.url as URL?, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems, !queryItems.isEmpty {
            // The URL states an order; `.sortedKeys` over a dictionary replaced
            // it with the alphabet, so the parameters never lined up with the
            // request they came from. (See OrderedJSON.)
            modelParams.content = OrderedJSON.text(from: queryItems.map {
                (key: $0.name, value: $0.value ?? "")
            })
        }
        modelParams.showPreview = true

        // Request header
        var model_2 = NetworkDetailSection(title: "REQUEST HEADER", content: nil, url: urlStr, httpModel: httpModel)
        if let requestHeaderFields = httpModel?.requestHeaderFields, requestHeaderFields.count > 0 {
            model_2 = NetworkDetailSection(title: "REQUEST HEADER", content: requestHeaderFields.description, url: urlStr, httpModel: httpModel)
            model_2.requestHeaderFields = requestHeaderFields as? [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: requestHeaderFields, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let jsonString = String(data: data, encoding: .utf8) {
                model_2.content = jsonString
                model_2.rawContent = jsonString
            }
        }
        model_2.showPreview = true

        // Request body
        var model_3 = NetworkDetailSection(title: "REQUEST", content: requestContent, url: urlStr, httpModel: httpModel)
        model_3.showPreview = true
        let reqBytes = Int(httpModel?.requestDataSize ?? 0)
        if reqBytes > 0 { model_3.sizeTag = "↑ \(formatBytes(reqBytes))" }

        // Response header
        var model_4 = NetworkDetailSection(title: "RESPONSE HEADER", content: nil, url: urlStr, httpModel: httpModel)
        if let responseHeaderFields = httpModel?.responseHeaderFields, responseHeaderFields.count > 0 {
            model_4 = NetworkDetailSection(title: "RESPONSE HEADER", content: responseHeaderFields.description, url: urlStr, httpModel: httpModel)
            model_4.responseHeaderFields = responseHeaderFields as? [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: responseHeaderFields, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let jsonString = String(data: data, encoding: .utf8) {
                model_4.content = jsonString
                model_4.rawContent = jsonString
            }
        }
        model_4.showPreview = true

        // Response body
        var model_5: NetworkDetailSection
        // An image only takes the image path when its bytes actually decode.
        // `isImage` can come from the URL's extension alone, so a .png endpoint
        // returning a JSON error envelope used to produce a section with neither
        // image nor text — which the filter below then dropped entirely, hiding a
        // response that was there and was exactly what you needed to read.
        let decodedImage: UIImage? = (httpModel?.isImage == true)
            ? cachedResponseData.flatMap { UIImage.imageWithGIFData($0) }
            : nil
        if let decodedImage {
            model_5 = NetworkDetailSection(title: "RESPONSE", content: nil, url: urlStr,
                                           image: decodedImage, httpModel: httpModel)
        } else {
            // One parse, in the ONE canonical pretty-printer. The inlined copy
            // that used to live here re-serialised through `JSONSerialization`
            // and so printed the body in hash order — the same screen's copy
            // button went through `dataToPrettyPrintString()` and printed it in
            // a different one. Preview and copy must be the same bytes.
            let prettyResponse = cachedResponseData?.dataToPrettyPrintString()
            model_5 = NetworkDetailSection(title: "RESPONSE", content: prettyResponse, url: urlStr, httpModel: httpModel)
        }
        model_5.showPreview = true
        // The body above is what the APP received, which is not what the server
        // sent when a rewrite fired. Say so on the section itself — a developer
        // reading a value that no server ever returned has to see it here, not
        // three hours into a phantom bug hunt. (See RESPONSE-REWRITE.)
        if httpModel?.isResponseRewritten == true {
            model_5.title = "RESPONSE  ·  ✎ REWRITTEN"
        }
        if httpModel?.isImage != true {
            let respBytes = Int(httpModel?.responseDataSize ?? 0)
            if respBytes > 0 {
                let encoding = (httpModel?.responseHeaderFields?["Content-Encoding"] as? String ?? "").lowercased()
                var tag = "↓ \(formatBytes(respBytes))"
                if encoding.contains("gzip") { tag += "  gzip" }
                else if encoding.contains("br") { tag += "  br" }
                model_5.sizeTag = tag
            }
        }

        // Errors (info-only sections — different styling, no preview)
        var model_6 = NetworkDetailSection(title: "ERROR", content: httpModel?.errorLocalizedDescription, url: urlStr, httpModel: httpModel)
        model_6.isInfoOnly = true
        var model_7 = NetworkDetailSection(title: "ERROR DESCRIPTION", content: httpModel?.errorDescription, url: urlStr, httpModel: httpModel)
        model_7.isInfoOnly = true

        // cURL command (pass cached data to avoid redundant disk read)
        rawCurlString = httpModel?.cURLDescription(cachedRequestData: cachedRequestData) ?? ""
        var modelCurl = NetworkDetailSection(title: "REQUEST CURL", content: rawCurlString, url: urlStr, httpModel: httpModel)
        modelCurl.showPreview = true

        // MARK: Timing
        var timingLines: [String] = []
        if let durStr = httpModel?.totalDuration {
            let cleaned = durStr.replacingOccurrences(of: " (s)", with: "").trimmingCharacters(in: .whitespaces)
            if let secs = Double(cleaned) {
                let ms = secs * 1000
                timingLines.append(ms < 1000
                    ? String(format: "Duration   %.0f ms", ms)
                    : String(format: "Duration   %.2f s", secs))
            }
        }
        if let startStr = httpModel?.startTime, let endStr = httpModel?.endTime {
            let startTs = (startStr as NSString).doubleValue
            let endTs   = (endStr   as NSString).doubleValue
            if startTs > 0 {
                let fmt = DateFormatter()
                fmt.dateFormat = "HH:mm:ss.SSS"
                timingLines.append("Started    " + fmt.string(from: Date(timeIntervalSince1970: startTs)))
                timingLines.append("Finished   " + fmt.string(from: Date(timeIntervalSince1970: endTs)))
            }
        }
        let modelTiming = NetworkDetailSection(
            title: "TIMING",
            content: timingLines.isEmpty ? nil : timingLines.joined(separator: "\n"),
            url: urlStr, httpModel: httpModel)

        // MARK: JWT
        var modelJWT = NetworkDetailSection(title: "JWT TOKEN", content: nil, url: urlStr, httpModel: httpModel)
        if let auth = httpModel?.requestHeaderFields?["Authorization"] as? String,
           auth.lowercased().hasPrefix("bearer ") {
            let token = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            let parts = token.components(separatedBy: ".")
            if parts.count >= 2 {
                var blocks: [String] = []
                // A JWT's claims are JSON somebody minted in a definite order —
                // printed through the same canonical helper as every other body
                // so the claims read the way the token spells them.
                if let data = Data(base64Encoded: padBase64(parts[0])),
                   data.dataToJSONObject() != nil,
                   let str = data.dataToPrettyPrintString() {
                    blocks.append("// HEADER\n\(str)")
                }
                if let data = Data(base64Encoded: padBase64(parts[1])),
                   let obj  = data.dataToJSONObject(),
                   let str = data.dataToPrettyPrintString() {
                    blocks.append("// PAYLOAD\n\(str)")
                    if let dict = obj as? [String: Any],
                       let expNum = dict["exp"] as? NSNumber {
                        let expDate = Date(timeIntervalSince1970: expNum.doubleValue)
                        let dateFmt = DateFormatter()
                        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                        if expDate > Date() {
                            let diff = expDate.timeIntervalSinceNow
                            let h = Int(diff) / 3600
                            let m = (Int(diff) % 3600) / 60
                            blocks.append("// EXPIRY\nExpires: \(dateFmt.string(from: expDate))\nExpires in: \(h)h \(m)m")
                        } else {
                            blocks.append("// EXPIRY\n⚠️ EXPIRED\nWas valid until: \(dateFmt.string(from: expDate))")
                        }
                    }
                }
                if !blocks.isEmpty {
                    modelJWT.content = blocks.joined(separator: "\n\n")
                    modelJWT.showPreview = true
                }
            }
        }

        // MARK: Error Details
        var modelErrorDetails = NetworkDetailSection(title: "ERROR DETAILS", content: nil, url: urlStr, httpModel: httpModel)
        let statusInt = Int(httpModel?.statusCode ?? "0") ?? 0
        var errorLines: [String] = []
        if statusInt >= 400 {
            let msg = HTTPURLResponse.localizedString(forStatusCode: statusInt).capitalized
            errorLines.append("HTTP \(statusInt)  \(msg)")
        }
        if let desc = httpModel?.errorLocalizedDescription, !desc.isEmpty {
            errorLines.append(desc)
        }
        if let extra = httpModel?.errorDescription, !extra.isEmpty,
           extra != httpModel?.errorLocalizedDescription {
            errorLines.append(extra)
        }
        if !errorLines.isEmpty {
            modelErrorDetails.content = errorLines.joined(separator: "\n")
            modelErrorDetails.isInfoOnly = true
        }

        // MARK: Cache Headers
        var cacheLines: [String] = []
        let respFields = httpModel?.responseHeaderFields

        func responseHeader(_ key: String) -> String? {
            guard let fields = respFields else { return nil }
            let lower = key.lowercased()
            for (k, v) in fields {
                if (k as? String)?.lowercased() == lower, let str = v as? String { return str }
            }
            return nil
        }

        if let cc = responseHeader("Cache-Control") {
            cacheLines.append("Cache-Control   \(cc)")
            let directives = cc.lowercased().components(separatedBy: ",")
                              .map { $0.trimmingCharacters(in: .whitespaces) }
            for d in directives {
                if d == "no-store"          { cacheLines.append("  → Not cached at all") }
                else if d == "no-cache"     { cacheLines.append("  → Must revalidate before each use") }
                else if d == "must-revalidate" { cacheLines.append("  → Must revalidate when stale") }
                else if d == "immutable"    { cacheLines.append("  → Content never changes") }
                else if d == "public"       { cacheLines.append("  → Cacheable by any cache") }
                else if d == "private"      { cacheLines.append("  → Browser-only cache") }
                else if d.hasPrefix("max-age="), let s = Int(d.dropFirst(8)), s >= 0 {
                    cacheLines.append("  → Fresh for \(humanDuration(s))")
                } else if d.hasPrefix("s-maxage="), let s = Int(d.dropFirst(9)), s >= 0 {
                    cacheLines.append("  → Shared cache: fresh for \(humanDuration(s))")
                } else if d.hasPrefix("stale-while-revalidate="), let s = Int(d.dropFirst(23)) {
                    cacheLines.append("  → Serve stale for \(humanDuration(s)) while revalidating")
                } else if d.hasPrefix("stale-if-error="), let s = Int(d.dropFirst(15)) {
                    cacheLines.append("  → Serve stale for \(humanDuration(s)) on error")
                }
            }
        }
        if let age = responseHeader("Age"), let ageSecs = Int(age) {
            cacheLines.append("Age             \(age)s  (cached \(humanDuration(ageSecs)) ago)")
        }
        if let etag = responseHeader("ETag") {
            cacheLines.append("ETag            \(etag)")
        }
        if let lastMod = responseHeader("Last-Modified") {
            cacheLines.append("Last-Modified   \(lastMod)")
        }
        if let expires = responseHeader("Expires") {
            cacheLines.append("Expires         \(expires)")
        }
        if let vary = responseHeader("Vary") {
            cacheLines.append("Vary            \(vary)")
        }
        if let pragma = responseHeader("Pragma") {
            cacheLines.append("Pragma          \(pragma)")
        }
        let modelCache = NetworkDetailSection(
            title: "CACHE HEADERS",
            content: cacheLines.isEmpty ? nil : cacheLines.joined(separator: "\n"),
            url: urlStr, httpModel: httpModel)

        // MARK: Response Rewrites (see RESPONSE-REWRITE)
        // Present whenever a rule had rewrites armed for this request — NOT only
        // when something changed. A rewrite that matched zero values is the
        // failure mode this codebase keeps producing, so it is listed with its
        // "matched 0" in full rather than vanishing.
        // A breakpoint that never paused is its own fact, under its own heading —
        // burying it in RESPONSE REWRITES is the last place anyone would look for
        // it, and it is what the inbox already reports while you are waiting.
        var modelBreakpoint = NetworkDetailSection(title: "BREAKPOINT", content: nil,
                                                   url: urlStr, httpModel: httpModel)
        if let reason = httpModel?.breakpointSkippedReason, !reason.isEmpty {
            modelBreakpoint.content = "\u{26A0}\u{FE0E} " + reason
        }

        var modelRewrites = NetworkDetailSection(title: "RESPONSE REWRITES", content: nil,
                                                 url: urlStr, httpModel: httpModel)
        // `isResponseRewritten` is included in the condition on purpose: a body
        // badged "REWRITTEN" with no section under it would be a badge with no
        // explanation, which is exactly the phantom bug hunt this exists to stop.
        if httpModel?.hasRewriteInfo == true || httpModel?.isResponseRewritten == true {
            var rewriteLines: [String] = []
            let changed = httpModel?.rewrittenValueCount ?? 0
            let notes = httpModel?.rewriteNotes ?? []
            if httpModel?.isResponseRewritten == true {
                rewriteLines.append("⚠︎ SwiftyDebug changed \(changed) "
                                    + (changed == 1 ? "value" : "values")
                                    + " in the body below. The server did not send this.")
            } else if !notes.isEmpty {
                rewriteLines.append("Nothing was changed — the body below is exactly "
                                    + "what the server sent.")
            }
            if let reason = httpModel?.rewriteSkippedReason, !reason.isEmpty {
                rewriteLines.append(reason)
            }
            if notes.isEmpty {
                // Every rewrite that runs leaves a note, so this only happens for
                // a record restored from before notes were persisted. Say that,
                // rather than leaving the badge unexplained.
                if httpModel?.isResponseRewritten == true {
                    rewriteLines.append("Per-rewrite detail was not recorded for this request.")
                }
            } else {
                // One block per rewrite that ran — name, how many values it
                // matched, how many it changed, and any engine error. Rewrites
                // that matched ZERO values are in here too; that is the whole
                // point of listing them.
                rewriteLines.append("")
                rewriteLines.append(contentsOf: notes)
                modelRewrites.sizeTag = notes.count == 1 ? "1 rewrite ran" : "\(notes.count) rewrites ran"
            }
            modelRewrites.content = rewriteLines.joined(separator: "\n")
            modelRewrites.isInfoOnly = true
        }

        // MARK: Rewrite entry point (see RESPONSE-REWRITE)
        // The three-tap flow starts here: this card → tap the value → Save.
        // Decided once, from the parse above, because `cellForRowAt` has to stay
        // pure layout — and because an action that is offered has to work.
        cachedResponseBody = cachedResponseData
        // The card was removed from this screen at the user's request. Rewrites
        // are authored from the intercept rule editor's RESPONSE REWRITES
        // section instead. The state stays `.hidden` so the row is never built.
        rewriteEntryState = .hidden
        // Content stays nil: the card draws its own text, so this section never
        // shows up in the copied/shared details.
        let modelRewriteAction = NetworkDetailSection(title: Self.rewriteActionTitle, content: nil,
                                                      url: urlStr, httpModel: httpModel)

        // Build final list — only include sections that have content.
        // URL is always included (hidden placeholder row).
        // REQUEST CURL is always included (useful even with just URL + method).
        // Everything else is filtered out when empty.
        // The rewrite card carries no content, so it is included by title.
        let alwaysInclude: Set<String> = ["URL", "REQUEST CURL", Self.rewriteActionTitle]

        // The card sits immediately under the response body — the moment you are
        // reading a value you want changed is the moment the action has to be
        // within reach.
        var allSections = [model_1, modelParams, model_2, model_3, model_4,
                           modelBreakpoint, modelRewrites, model_5]
        if !rewriteEntryState.isHidden { allSections.append(modelRewriteAction) }
        allSections += [model_6, model_7, modelCurl,
                        modelTiming, modelJWT, modelErrorDetails, modelCache]
        for section in allSections {
            let title = section.title ?? ""
            if alwaysInclude.contains(title) {
                detailModels.append(section)
            } else if section.image != nil {
                detailModels.append(section)
            } else if let content = section.content, !content.isEmpty {
                detailModels.append(section)
            }
        }

        // MARK: Similar Requests — same host + normalized path (numbers/UUIDs stripped)
        let currentHost     = httpModel?.url?.host ?? ""
        let currentNormPath = Self.normalizedPath(httpModel?.url as URL?)

        let capped: [NetworkTransaction]
        if let current = httpModel, !currentNormPath.isEmpty {
            capped = Array((httpModels ?? []).filter { model in
                guard model !== current else { return false }
                return model.url?.host == currentHost
                    && Self.normalizedPath(model.url as URL?) == currentNormPath
            }.prefix(10))
        } else {
            capped = []
        }
        if !capped.isEmpty {
            var modelSimilar = NetworkDetailSection(title: "SIMILAR REQUESTS", content: nil, url: urlStr, httpModel: httpModel)
            modelSimilar.similarRequests = capped
            detailModels.append(modelSimilar)
        }

        // MARK: Media — images parsed from the response JSON (see JSON-MEDIA)
        let mediaURLs = httpModel?.imageURLs ?? []
        if !mediaURLs.isEmpty {
            var modelMedia = NetworkDetailSection(title: "MEDIA", content: nil, url: urlStr, httpModel: httpModel)
            modelMedia.mediaImageURLs = mediaURLs
            detailModels.append(modelMedia)
        }
    }
    
    // MARK: - Helpers

    /// Normalizes a URL path for endpoint matching:
    /// - replaces purely-numeric segments  (/orders/123  → /orders/*)
    /// - replaces UUID-like segments        (/users/550e8400-…  → /users/*)
    /// - ignores query parameters entirely
    private static func normalizedPath(_ url: URL?) -> String {
        guard let path = url?.path, !path.isEmpty else { return "" }
        return path
            .components(separatedBy: "/")
            .map { seg -> String in
                guard !seg.isEmpty else { return seg }
                // Purely numeric
                if seg.allSatisfy({ $0.isNumber }) { return "*" }
                // UUID (8-4-4-4-12 hex + hyphens)
                if seg.count == 36,
                   seg.filter({ $0 == "-" }).count == 4,
                   seg.replacingOccurrences(of: "-", with: "").allSatisfy({ $0.isHexDigit }) {
                    return "*"
                }
                return seg
            }
            .joined(separator: "/")
    }

    // MARK: - Response rewrite flow (see RESPONSE-REWRITE)

    /// Whether "Rewrite a value…" is offered, and if not, whether that is worth
    /// saying out loud. `.blocked` is deliberately preferred over hiding whenever
    /// there IS a body on screen: "why is there no rewrite button" has to have an
    /// answer where the body is.
    private static func rewriteEntry(body: Data?, root: Any?, url: URL?,
                                     isImage: Bool, isReplayResult: Bool) -> RewriteEntryState {
        // A replay result is a one-off the developer fired by hand; the screen
        // already hides Intercept/Replay there, and a rule armed from it would
        // silently apply to live traffic instead.
        guard !isReplayResult else { return .hidden }
        // Without a URL there is nothing to scope an intercept rule to.
        guard url != nil else { return .hidden }
        // No body, or a body that is a picture: nothing is being read, so there
        // is no question to answer.
        guard let body = body, !body.isEmpty, !isImage else { return .hidden }

        guard body.count <= ResponseRewriteEngine.maxBodyBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .binary)
            return .blocked("Can't rewrite this one: the body is \(size), over the "
                            + "\(ResponseRewriteEngine.maxBodyBytes / 1024 / 1024) MB limit, "
                            + "so rewrites are skipped for responses this big.")
        }
        guard root != nil else {
            return .blocked("Can't rewrite this one: the body isn't JSON, so it has no "
                            + "named values to change.")
        }
        return .ready
    }

    /// Tap 1 of 3. Opens the response as a tree in picker mode — one tap on the
    /// value is tap 2, and the editor it lands in is pre-filled well enough that
    /// Save is tap 3.
    private func startRewriteFlow() {
        guard case .ready = rewriteEntryState,
              let body = cachedResponseBody,          // already in memory, no disk read
              let url = httpModel?.url as URL?,
              let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else { return }

        let picker = JSONEditorViewController(document: JSONDocument(root: root),
                                              title: "Tap the value to rewrite")
        picker.onPickPath = { [weak self] path in
            guard let self = self else { return }
            // The picker pops ITSELF as soon as this returns. Pushing the editor
            // here would put it underneath that pop and it would vanish, so hand
            // it to the next runloop turn instead.
            DispatchQueue.main.async { [weak self] in
                self?.pushRewriteEditor(seedPath: path, body: body, url: url)
            }
        }
        if let nav = navigationController {
            nav.pushViewController(picker, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: picker), animated: true)
        }
    }

    /// Tap 3 lives here. `.rule(forURL:)` is used rather than `.caller` because
    /// no rule is open — the editor owns creating (or reusing) an intercept rule
    /// and showing the APPLIES TO scope choice for it.
    private func pushRewriteEditor(seedPath: JSONPath, body: Data, url: URL) {
        let editor = ResponseRewriteEditorViewController(
            rewrite: nil,
            sampleBody: body,
            sampleLabel: url.absoluteString,
            seedPath: seedPath,
            destination: .rule(forURL: url))

        guard let nav = navigationController else {
            // No nav of our own: the picker was presented modally inside one, so
            // the editor goes on top of THAT stack. Presenting from self while it
            // is already presenting the picker would just be dropped.
            if let modalNav = presentedViewController as? UINavigationController {
                modalNav.pushViewController(editor, animated: true)
            } else {
                (presentedViewController ?? self)
                    .present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
            }
            return
        }
        // The picker's pop is still animating at this point; pushing into a
        // running transition is what corrupts the navigation bar.
        if let coordinator = nav.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in
                nav.pushViewController(editor, animated: true)
            }
        } else {
            nav.pushViewController(editor, animated: true)
        }
    }

    private func humanDuration(_ seconds: Int) -> String {
        if seconds < 60   { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60; let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        let h = seconds / 3600; let m = (seconds % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func padBase64(_ s: String) -> String {
        var padded = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return padded
    }

    //detetc request format (JSON/Form)
    func detectRequestSerializer() {
        guard let requestData = httpModel?.requestData else {
            httpModel?.requestSerializer = RequestSerializer.json//default JSON format
            return
        }
        
        if let _ = requestData.dataToDictionary() {
            //JSON format
            httpModel?.requestSerializer = RequestSerializer.json
        } else {
            //Form format
            httpModel?.requestSerializer = RequestSerializer.form
        }
    }
    
    
    private func buildMessageBody() -> String {
        var body = ""
        var seenSections = Set<String>()

        for model in detailModels {
            guard let title = model.title, let content = model.content, !content.isEmpty else { continue }
            // Dedup by exact section identity, not substring-containment. The old
            // `body.contains(string)` check could silently drop a section whose
            // text happened to be a substring of an earlier one, producing an
            // "incomplete" copy. (See COPY.)
            let section = "\n\n" + "------- " + title + " -------" + "\n" + content
            guard seenSections.insert(section).inserted else { continue }
            body.append(section)
        }

        let url = httpModel?.url?.absoluteString ?? ""
        let method = "[" + (httpModel?.method ?? "") + "]"

        var time = ""
        if let startTime = httpModel?.startTime {
            if (startTime as NSString).doubleValue == 0 {
                time = LogDateFormatter.formatDate(Date())
            } else {
                time = LogDateFormatter.formatDate(NSDate(timeIntervalSince1970: (startTime as NSString).doubleValue) as Date)
            }
        }

        var statusCode = httpModel?.statusCode ?? ""
        if statusCode == "0" { statusCode = "❌" }

        var subString = method + " " + time + " " + "(" + statusCode + ")"
        if subString.contains("❌") {
            subString = subString.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }

        body = body.replacingOccurrences(of: "https://github.com/SwiftyDebug/SwiftyDebug", with: url)
        return subString + body
    }
    
    
    //MARK: - init
    override func viewDidLoad() {
        super.viewDidLoad()
        
        naviItemTitleLabel = UILabel.init(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        naviItemTitleLabel?.textAlignment = .center
        naviItemTitleLabel?.textColor = DebugTheme.accentColor
        naviItemTitleLabel?.font = .boldSystemFont(ofSize: 20)
        naviItemTitleLabel?.text = "Details"
        navigationItem.titleView = naviItemTitleLabel

        let closeImage = UIImage(systemName: "xmark")
        closeItem = UIBarButtonItem(image: closeImage, style: .plain, target: self, action: #selector(close(_:)))
        closeItem.tintColor = DebugTheme.accentColor
        
        //detect the request format (JSON/Form)
        detectRequestSerializer()

        buildDetailModels()

        //Register programmatic cells (overrides storyboard prototypes)
        tableView.register(NetworkCell.self, forCellReuseIdentifier: "NetworkCell")
        tableView.register(NetworkDetailCell.self, forCellReuseIdentifier: "NetworkDetailCell")
        tableView.register(NetworkSimilarRequestsCell.self, forCellReuseIdentifier: "NetworkSimilarRequestsCell")
        tableView.register(NetworkMediaGridCell.self, forCellReuseIdentifier: "NetworkMediaGridCell")
        tableView.register(NetworkRewriteActionCell.self,
                           forCellReuseIdentifier: NetworkRewriteActionCell.reuseID)

        // Table styling
        tableView.backgroundColor = .black
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.contentInset.bottom = 16
        tableView.showsVerticalScrollIndicator = false

        // Pin button
        let pinImage = (httpModel?.isPinned == true)
            ? UIImage(systemName: "pin.slash.fill")
            : UIImage(systemName: "pin.fill")
        pinItem = UIBarButtonItem(image: pinImage, style: .plain, target: self, action: #selector(togglePin))
        pinItem.tintColor = DebugTheme.accentColor

        // Share/export button — exports the response JSON as a .json file.
        let shareItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain, target: self, action: #selector(exportResponseJSON(_:))
        )
        shareItem.tintColor = DebugTheme.accentColor

        // Nav bar — close / pin / share are always available (including on a
        // replay result). Intercept & Replay live in the header card instead.
        navigationItem.rightBarButtonItems = [closeItem, pinItem, shareItem]

        //header
        headerCell = NetworkCell(style: .default, reuseIdentifier: "NetworkCell")
        headerCell?.httpModel = httpModel
        headerCell?.showCurlButton = true
        headerCell?.onCurlTapped = { [weak self] in
            guard let self = self else { return }
            // Use rawCurlString — NOT detailModel.content which has \/ replaced
            let curl = self.rawCurlString
            UIPasteboard.general.string = curl

            let activity = UIActivityViewController(activityItems: [curl], applicationActivities: nil)
            if UIDevice.current.userInterfaceIdiom == .pad {
                activity.popoverPresentationController?.sourceView = self.view
                activity.popoverPresentationController?.sourceRect = CGRect(
                    x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0
                )
            }
            self.present(activity, animated: true)
        }

        // Replay sits directly under Intercept in the header card. Both are
        // hidden when this screen is showing the result of a replay.
        headerCell?.showReplayButton = !isReplayResult && RequestReplayViewController.canReplay(httpModel)
        headerCell?.onReplayTapped = { [weak self] in
            self?.replayTapped()
        }

        headerCell?.showInterceptButton = !isReplayResult
        headerCell?.onInterceptTapped = { [weak self] in
            guard let self = self, let model = self.httpModel else { return }
            guard let url = model.url as URL? else { return }
            let existingRules = InterceptRuleStore.shared.matchingRules(forURL: url)

            if existingRules.isEmpty {
                // No rules yet — ask which scope to create. Uses the custom picker
                // (not a system action sheet) so long endpoints/hosts aren't
                // truncated. (See INTERCEPT-UX.)
                let openEditor: (EndpointMatchMode) -> Void = { [weak self] mode in
                    guard let self else { return }
                    let editor = InterceptRuleEditorViewController()
                    editor.httpModel = model
                    editor.initialMatchMode = mode
                    self.present(SwiftyDebugNavigationController(rootViewController: editor), animated: true)
                }
                let normalized = EndpointNormalizer.normalize(url.path)
                let host = url.host ?? ""

                OptionPickerSheetViewController.present(
                    from: self,
                    title: "Intercept Rule",
                    message: "Choose what this rule should apply to.",
                    options: [
                        .init(title: "This Endpoint",
                              subtitle: normalized.isEmpty ? url.path : normalized,
                              symbol: "point.topleft.down.curvedto.point.bottomright.up",
                              tint: DebugTheme.accentColor) { openEditor(.normalized) },
                        .init(title: "This Host",
                              subtitle: host.isEmpty ? "every request to this host" : host,
                              symbol: "network", tint: .systemPurple) { openEditor(.host) },
                        .init(title: "Global",
                              subtitle: "Every request in the app and web views",
                              symbol: "globe", tint: .systemPink) { openEditor(.global) },
                    ]
                )
            } else {
                // Rules exist — show the rule list manager
                let list = InterceptRuleListViewController()
                list.httpModel = model
                let nav = SwiftyDebugNavigationController(rootViewController: list)
                self.present(nav, animated: true)
            }
        }
        view.forceLTR()
    }

    private var hasPerformedInitialReload = false

    /// True between the `viewWillDisappear` release below and the next
    /// appearance. Only a CANCELLED pop can observe it as true, and that is
    /// exactly the case `viewDidAppear` has to undo.
    private var didReleaseCachedContent = false

    /// Builds `detailModels` from scratch and marks the closing section.
    ///
    /// `setupModels()` APPENDS, so the list is always cleared first — a rebuild
    /// that skipped this would render every section twice.
    private func buildDetailModels() {
        detailModels.removeAll()
        setupModels()

        if var lastModel = detailModels.last {
            lastModel.isLast = true
            detailModels.removeLast()
            detailModels.append(lastModel)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // A swipe-back that the user abandoned. `isMovingFromParent` is already
        // true when the gesture STARTS, so `viewWillDisappear` released the
        // sections and the cached body — and then UIKit reversed the transition
        // and left this screen in front of the user with nothing in it: no rows,
        // and Copy / Share producing a header line with no request in it.
        // Rebuild what was released. A real pop never gets here.
        guard didReleaseCachedContent else { return }
        didReleaseCachedContent = false

        buildDetailModels()
        tableView.reloadData()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // After the table gets its correct width, reload once so
        // self-sizing cells and the sticky header compute correct heights.
        if !hasPerformedInitialReload {
            hasPerformedInitialReload = true
            tableView.reloadData()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Only run cleanup when actually going back (popped), not when pushing a child VC
        guard isMovingFromParent || isBeingDismissed else { return }

        if let index = httpModels?.firstIndex(where: { (model) -> Bool in
            return model.isSelected == true
        }) {
            httpModels?[index].isSelected = false
        }

        httpModel?.isSelected = true

        if let justCancelCallback = justCancelCallback {
            justCancelCallback()
        }

        // Release large strings (response body, request body) immediately
        // when navigating away instead of waiting for dealloc.
        //
        // This also runs the moment an interactive pop STARTS, which is not yet
        // a decision to leave — `viewDidAppear` puts it all back if the gesture
        // is cancelled.
        detailModels.removeAll()
        cachedResponseBody = nil
        didReleaseCachedContent = true
    }
    
    //MARK: - target action

    @objc func close(_ sender: UIBarButtonItem) {
        self.navigationController?.dismiss(animated: true)
    }

    /// Opens the replay editor pre-filled with this request. (See REPLAY.)
    @objc private func replayTapped() {
        guard let model = httpModel else { return }
        let replay = RequestReplayViewController(model: model)
        if let nav = navigationController {
            nav.pushViewController(replay, animated: true)
        } else {
            present(SwiftyDebugNavigationController(rootViewController: replay), animated: true)
        }
    }

    @objc private func togglePin() {
        guard let model = httpModel else { return }
        model.isPinned.toggle()
        if model.isPinned {
            model.savePinToDisk()
        } else {
            model.removePinFromDisk()
        }
        pinItem.image = model.isPinned
            ? UIImage(systemName: "pin.slash.fill")
            : UIImage(systemName: "pin.fill")
    }

    /// Export/share menu for the current request. Offers exporting the response
    /// JSON as a `.json` file (share sheet), plus the existing text/cURL shares.
    /// (See EXPORT-SHARE.)
    @objc func exportResponseJSON(_ sender: UIBarButtonItem) {
        let alert = UIAlertController(title: "Export / Share", message: nil, preferredStyle: .actionSheet)

        // Response JSON as a file (the primary new capability).
        let responseString = httpModel?.responseData?.dataToPrettyPrintString()
        if let responseString, !responseString.isEmpty {
            alert.addAction(UIAlertAction(title: "Export Response as .json file", style: .default) { [weak self] _ in
                self?.shareAsFile(jsonText: responseString, kind: "response", sourceItem: sender)
            })
        }

        // Request body as a file, when present.
        let requestString = httpModel?.requestData?.dataToPrettyPrintString()
        if let requestString, !requestString.isEmpty {
            alert.addAction(UIAlertAction(title: "Export Request as .json file", style: .default) { [weak self] _ in
                self?.shareAsFile(jsonText: requestString, kind: "request", sourceItem: sender)
            })
        }

        // Full text (all sections) — copy + share as before.
        alert.addAction(UIAlertAction(title: "Share full details (text)", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let items: [Any] = [self.messageBody]
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            self.presentActivity(activity, sourceItem: sender)
        })

        alert.addAction(UIAlertAction(title: "Copy cURL", style: .default) { [weak self] _ in
            UIPasteboard.general.string = self?.rawCurlString
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad anchor
        alert.popoverPresentationController?.barButtonItem = sender
        present(alert, animated: true)
    }

    /// Export/share-ready text for a body that has already been through the
    /// canonical pretty-printer.
    ///
    /// `renderedBody` is whatever `dataToPrettyPrintString()` returned: valid
    /// JSON in the server's key order, or the raw text when the body was not
    /// JSON. Re-serialising it here — which is what a `JSONSerialization`-based
    /// normaliser does — parses it back into an unordered dictionary and
    /// alphabetises the very keys the preview just got right. Trim the bytes
    /// that were already rendered and ship those, so the exported file, the
    /// clipboard and the screen all say the same thing.
    static func exportText(for renderedBody: String) -> String {
        return renderedBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes a JSON string to a temp file and shares the file URL.
    private func shareAsFile(jsonText: String, kind: String, sourceItem: UIBarButtonItem) {
        let contents = Self.exportText(for: jsonText)
        let host = httpModel?.url?.host ?? "request"
        let path = (httpModel?.url?.path ?? "").replacingOccurrences(of: "/", with: "-")
        let name = "\(host)\(path)-\(kind)"
        guard let fileURL = JSONExporter.writeTemporaryFile(contents: contents, suggestedName: name) else { return }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        presentActivity(activity, sourceItem: sourceItem)
    }

    private func presentActivity(_ activity: UIActivityViewController, sourceItem: UIBarButtonItem) {
        activity.popoverPresentationController?.barButtonItem = sourceItem
        present(activity, animated: true)
    }

    @objc func didTapMail(_ sender: UIBarButtonItem) {

        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "copy to clipboard", style: .default) { [weak self] _ in
            UIPasteboard.general.string = self?.messageBody
        })

        alert.addAction(UIAlertAction(title: "copy cURL to clipboard", style: .default) { [weak self] _ in
            if let httpModel = self?.httpModel {
                let curl = httpModel.cURLDescription()
                UIPasteboard.general.string = curl
            }
        })

        alert.addAction(UIAlertAction(title: "share", style: .default) { [weak self] _ in
            let items: [Any] = [self?.messageBody ?? ""]
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if UIDevice.current.userInterfaceIdiom == .phone {
                self?.present(activity, animated: true)
            } else {
                activity.popoverPresentationController?.sourceRect = .init(x: self?.view.bounds.midX ?? 0, y: self?.view.bounds.midY ?? 0, width: 0, height: 0)
                activity.popoverPresentationController?.sourceView = self?.view
                self?.present(activity, animated: true)
            }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.popoverPresentationController?.permittedArrowDirections = .init(rawValue: 0)
        alert.popoverPresentationController?.sourceView = self.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)

        present(alert, animated: true)
    }
}

//MARK: - UITableViewDataSource
extension NetworkDetailViewController {
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // +1 for the header cell at row 0
        return detailModels.count + 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Row 0: header cell (non-sticky)
        if indexPath.row == 0 {
            return headerCell ?? UITableViewCell()
        }

        let detailIndex = indexPath.row - 1
        guard detailIndex < detailModels.count else {
            return tableView.dequeueReusableCell(withIdentifier: "NetworkDetailCell", for: indexPath)
        }
        let model = detailModels[detailIndex]

        // Similar Requests row — horizontal card scroll
        if let similar = model.similarRequests, !similar.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkSimilarRequestsCell", for: indexPath)
                as! NetworkSimilarRequestsCell
            cell.configure(with: similar)
            cell.onTap = { [weak self] tappedModel in
                guard let self = self else { return }
                let vc = NetworkDetailViewController(style: .plain)
                vc.httpModel  = tappedModel
                vc.httpModels = self.httpModels
                self.navigationController?.pushViewController(vc, animated: true)
            }
            return cell
        }

        // Media grid — images parsed from the response JSON (see JSON-MEDIA)
        if let mediaURLs = model.mediaImageURLs, !mediaURLs.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkMediaGridCell", for: indexPath)
                as! NetworkMediaGridCell
            cell.configure(imageURLs: mediaURLs)
            let openGallery: (Int) -> Void = { [weak self] startIndex in
                guard let self = self else { return }
                let gallery = MediaGalleryViewController(imageURLs: mediaURLs, title: "Media")
                self.navigationController?.pushViewController(gallery, animated: true)
                _ = startIndex
            }
            cell.onSelectImage = openGallery
            cell.onShowAll = { openGallery(0) }
            return cell
        }

        // Rewrite entry point — the card that starts the three-tap flow. Its
        // state was decided in setupModels; nothing here parses or reads disk.
        if model.title == Self.rewriteActionTitle {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NetworkRewriteActionCell.reuseID, for: indexPath)
                as! NetworkRewriteActionCell
            switch rewriteEntryState {
            case .ready:
                cell.configure(isActionable: true,
                               title: "Rewrite a value\u{2026}",
                               subtitle: "Change it automatically on every response")
            case .blocked(let reason):
                cell.configure(isActionable: false, title: "Rewrite a value", subtitle: reason)
            case .hidden:
                // Unreachable: a hidden card is never added to detailModels.
                cell.configure(isActionable: false, title: "Rewrite a value",
                               subtitle: "Not available for this response.")
            }
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "NetworkDetailCell", for: indexPath)
            as! NetworkDetailCell
        cell.detailModel = model

        //2.click edit view
        cell.tapEditViewCallback = { [weak self] detailModel in
            guard let self = self else { return }
            let content = detailModel?.content ?? ""

            // cURL section → open cURL preview with RAW string (not processed by NetworkDetailSection)
            if detailModel?.title == "REQUEST CURL" {
                let vc = CurlPreviewViewController()
                vc.curlString = self.rawCurlString
                self.navigationController?.pushViewController(vc, animated: true)
                return
            }

            self.pushJSONViewerOrFallback(with: content)
        }

        return cell
    }
}

//MARK: - UITableViewDelegate
extension NetworkDetailViewController {
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // Row 0: header cell
        if indexPath.row == 0 {
            return UITableView.automaticDimension
        }

        let detailIndex = indexPath.row - 1
        guard detailIndex < detailModels.count else { return 0 }

        // URL placeholder — hidden
        if detailModels[detailIndex].title == "URL" { return 0 }

        return UITableView.automaticDimension
    }

    /// The only selectable row on this screen: the rewrite card, and only when
    /// it can actually do something. A blocked card explains itself in place and
    /// does not pretend to be a button.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let detailIndex = indexPath.row - 1
        guard detailModels.indices.contains(detailIndex),
              detailModels[detailIndex].title == Self.rewriteActionTitle,
              case .ready = rewriteEntryState else { return }
        startRewriteFlow()
    }
}

// MARK: - Rewrite action card

/// The card under the response body that turns "I keep changing this value by
/// hand" into an armed rewrite. It is a plain row rather than a button on the
/// RESPONSE card because it needs a line of explanation next to it — the whole
/// point is that the change happens on *every* future response, and that has to
/// be said before it is agreed to.
///
/// When the response cannot be rewritten the card stays put and carries the
/// reason instead of disappearing, so "where is the rewrite action" always has
/// an answer at the place the question is asked.
final class NetworkRewriteActionCell: UITableViewCell {

    static let reuseID = "NetworkRewriteActionCell"

    private static let cardColor = UIColor(white: 0.11, alpha: 1)
    private static let highlightColor = UIColor(white: 0.16, alpha: 1)

    private let cardView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView()

    /// Per-row flag — reset in prepareForReuse so a recycled card never keeps a
    /// previous row's highlight behaviour.
    private var isActionable = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        cardView.backgroundColor = Self.cardColor
        cardView.layer.cornerRadius = 10
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = DebugTheme.accentColor.withAlphaComponent(0.35).cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stack)

        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfig)?
            .withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(chevronView)

        let cardBottom = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3)
        cardBottom.priority = UILayoutPriority(999)

        // The stack is pinned to BOTH the top and the bottom of the card, and the
        // card to both edges of the contentView — self-sizing depends on it.
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            cardBottom,

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),

            chevronView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            chevronView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
        ])
        forceLTR()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActionable = false
        titleLabel.text = nil
        subtitleLabel.text = nil
        iconView.image = nil
        chevronView.isHidden = true
        cardView.backgroundColor = Self.cardColor
    }

    func configure(isActionable: Bool, title: String, subtitle: String) {
        self.isActionable = isActionable
        titleLabel.text = title
        subtitleLabel.text = subtitle

        let tint = isActionable ? DebugTheme.accentColor : UIColor(white: 0.42, alpha: 1)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.image = UIImage(systemName: "wand.and.stars", withConfiguration: iconConfig)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)

        titleLabel.textColor = isActionable ? .white : UIColor(white: 0.55, alpha: 1)
        // The unavailable reason is the point of the card in that state, so it is
        // the loud element rather than a grey aside.
        subtitleLabel.textColor = isActionable ? UIColor(white: 0.55, alpha: 1) : .systemOrange
        chevronView.isHidden = !isActionable
        cardView.layer.borderColor = (isActionable
            ? DebugTheme.accentColor.withAlphaComponent(0.35)
            : UIColor(white: 0.20, alpha: 1)).cgColor
        cardView.backgroundColor = Self.cardColor
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        guard isActionable else { return }
        cardView.backgroundColor = highlighted ? Self.highlightColor : Self.cardColor
    }
}



// MARK: - JSON validity check
@inline(__always)
func isValidJSON(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8), !data.isEmpty else { return false }
    do {
        _ = try JSONSerialization.jsonObject(with: data, options: [])
        return true
    } catch {
        return false
    }
}

// MARK: - Push logic
extension UIViewController {
    func pushJSONViewerOrFallback(with jsonString: String) {
        let controller: UIViewController
        if isValidJSON(jsonString) {
            let vc = DemoJSONViewerHostController()
            vc.jsonString = jsonString
            controller = vc
        } else {
            let vc = JsonViewController()
            var model = NetworkDetailSection(title: "Preview", content: jsonString, url: nil, httpModel: nil)
            model.showPreview = false
            vc.detailModel = model
            controller = vc
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

import UIKit
import WebKit

// Bridges navigator.clipboard.writeText() from WKWebView to UIPasteboard.
// WKWebView blocks the Clipboard API when the page origin is null (loadHTMLString).
private final class ClipboardMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        UIPasteboard.general.string = text
    }
}

// JSON Viewer using https://github.com/andypf/json-viewer (web component)
final class JSONViewerViewController: UIViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var isLoaded = false
    private var pendingJSON: String?
    private let clipboardHandler = ClipboardMessageHandler()

    private let initialHTML: String = """
    <!doctype html>
    <html lang="ar" dir="auto">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <style>
        html, body { height:100%; margin:0; background:#0f1115; color:#e6e6e6;
          font-family:-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial,
          "Apple Color Emoji", "Segoe UI Emoji", "Noto Sans Arabic", "Geeza Pro", "PingFang SC",
          "Noto Sans", sans-serif; }
        #root { height:100%; display:grid; }
        andypf-json-viewer { height:100%; width:100%; }
        :root { unicode-bidi: plaintext; }
      </style>
      <script defer src="https://pfau-software.de/json-viewer/dist/iife/index.js"></script>
    </head>
    <body>
      <div id="root">
        <andypf-json-viewer
          id="viewer"
          indent="2"
          expanded="2"
          theme="onedark"
          show-data-types="true"
          show-toolbar="true"
          expand-icon-type="arrow"
          show-copy="true"
          show-size="true"
        >{}</andypf-json-viewer>
      </div>

      <script>
        function getViewer(){ return document.getElementById("viewer"); }

        function b64ToUtf8(b64) {
          const bin = atob(b64);
          const bytes = Uint8Array.from(bin, c => c.charCodeAt(0));
          if (window.TextDecoder) {
            return new TextDecoder("utf-8").decode(bytes);
          }
          let out = "", i = 0;
          while (i < bytes.length) out += String.fromCharCode(bytes[i++]);
          return decodeURIComponent(escape(out));
        }

        window.renderBase64 = (b64) => {
          try {
            const jsonText = b64ToUtf8(b64);
            const obj = JSON.parse(jsonText);
            getViewer().data = obj;
          } catch (e) { console.error("renderBase64 error", e); }
        };

        window.configureViewer = (opts = {}) => {
          const el = getViewer();
          if (typeof opts.indent === "number") el.indent = opts.indent;
          if (typeof opts.expanded !== "undefined") el.expanded = opts.expanded;
          if (typeof opts.theme === "string") el.theme = opts.theme;
          if (typeof opts.showDataTypes === "boolean") el.showDataTypes = opts.showDataTypes;
          if (typeof opts.showToolbar === "boolean") el.showToolbar = opts.showToolbar;
          if (typeof opts.expandIconType === "string") el.expandIconType = opts.expandIconType;
          if (typeof opts.showCopy === "boolean") el.showCopy = opts.showCopy;
          if (typeof opts.showSize === "boolean") el.showSize = opts.showSize;
          if (typeof opts.direction === "string") document.documentElement.setAttribute("dir", opts.direction);
        };
      </script>
    </body>
    </html>
    """


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Limit WKWebView memory: disable back-forward cache
        config.suppressesIncrementalRendering = true

        // Override navigator.clipboard.writeText so the json-viewer copy button
        // works when the page has a null origin (WKWebView blocks Clipboard API otherwise).
        let clipboardOverride = WKUserScript(
            source: """
            navigator.clipboard = {
              writeText: function(text) {
                window.webkit.messageHandlers.nativeClipboard.postMessage(text);
                return Promise.resolve();
              },
              readText: function() { return Promise.resolve(""); }
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(clipboardOverride)
        config.userContentController.add(clipboardHandler, name: "nativeClipboard")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        webView.loadHTMLString(initialHTML, baseURL: nil)
        view.forceLTR()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Only tear down when actually leaving (popped/dismissed), not when pushing a child.
        guard isMovingFromParent || isBeingDismissed else { return }
        tearDownWebView()
    }

    deinit {
        tearDownWebView()
    }

    /// Release WKWebView and all associated memory.
    /// WKWebView is known for retaining large JS heaps even after the VC is gone.
    private func tearDownWebView() {
        pendingJSON = nil
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "nativeClipboard")
        // Load blank page to force JS engine to release parsed JSON objects
        wv.loadHTMLString("", baseURL: nil)
        wv.removeFromSuperview()
        webView = nil
        isLoaded = false
    }

    // MARK: - Public API

    /// Pass a JSON string (UTF-8). Arabic is fully supported.
    func render(jsonString: String) {
        guard isLoaded else {
            pendingJSON = jsonString
            return
        }
        evaluateRender(jsonString: jsonString)
    }

    /// Optionally force RTL/LTR or tweak viewer.
    func configure(indent: Int? = nil,
                   expanded: Any? = nil,          // Int or Bool
                   theme: String? = nil,
                   showDataTypes: Bool? = nil,
                   showToolbar: Bool? = nil,
                   expandIconType: String? = nil, // "square" | "circle" | "arrow"
                   showCopy: Bool? = nil,
                   showSize: Bool? = nil,
                   direction: String? = nil       // "rtl" | "ltr" | "auto"
    ) {
        var dict: [String: Any] = [:]
        if let indent { dict["indent"] = indent }
        if let expanded {
            if let b = expanded as? Bool { dict["expanded"] = b }
            else if let i = expanded as? Int { dict["expanded"] = i }
        }
        if let theme { dict["theme"] = theme }
        if let showDataTypes { dict["showDataTypes"] = showDataTypes }
        if let showToolbar { dict["showToolbar"] = showToolbar }
        if let expandIconType { dict["expandIconType"] = expandIconType }
        if let showCopy { dict["showCopy"] = showCopy }
        if let showSize { dict["showSize"] = showSize }
        if let direction { dict["direction"] = direction }

        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
            let json = String(data: data, encoding: .utf8)
        else { return }

        webView?.evaluateJavaScript("window.configureViewer(\(json));", completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if let text = pendingJSON {
            evaluateRender(jsonString: text)
            pendingJSON = nil
        }
    }

    // MARK: - Internal

    private func evaluateRender(jsonString: String) {
        let b64 = Data(jsonString.utf8).base64EncodedString()
        let js = "window.renderBase64('\(b64)');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - Example Usage

final class DemoJSONViewerHostController: UIViewController {
    private let viewer = JSONViewerViewController()
    var jsonString: String = ""
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(viewer)
        viewer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewer.view)
        viewer.didMove(toParent: self)
        NSLayoutConstraint.activate([
            viewer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewer.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Optional configuration
        viewer.configure(indent: 2,
                         expanded: 2,
                         theme: "onedark",
                         showDataTypes: true,
                         showToolbar: true,
                         expandIconType: "arrow",
                         showCopy: true,
                         showSize: true)

        // Render JSON passed as STRING

        viewer.render(jsonString: jsonString)
        view.forceLTR()
    }
}

// MARK: - CurlPreviewViewController

final class CurlPreviewViewController: UIViewController {

    var curlString: String = ""

    private let scrollView = UIScrollView()
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let textView = UITextView()
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Nav title
        let navTitle = UILabel()
        navTitle.text = "cURL"
        navTitle.font = .boldSystemFont(ofSize: 20)
        navTitle.textColor = DebugTheme.accentColor
        navigationItem.titleView = navTitle

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        view.addSubview(scrollView)

        // Card (same as NetworkDetailCell)
        cardView.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(cardView)

        // Section title (same style as detail sections)
        titleLabel.text = "cURL COMMAND"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = UIColor(red: 0.29, green: 0.76, blue: 0.76, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        // cURL text
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = highlightCurl(curlString)
        textView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(textView)

        // Buttons row
        let buttonsStack = UIStackView()
        buttonsStack.axis = .horizontal
        buttonsStack.spacing = 8
        buttonsStack.distribution = .fillEqually
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(buttonsStack)

        // Copy button (same style as "Copy cURL" in NetworkCell)
        copyButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        copyButton.layer.cornerRadius = 6
        copyButton.clipsToBounds = true
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        if let icon = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))?.withRenderingMode(.alwaysTemplate) {
            copyButton.setImage(icon, for: .normal)
        }
        var copyConfig = UIButton.Configuration.plain()
        copyConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        copyConfig.imagePadding = 5
        copyConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        copyConfig.baseForegroundColor = DebugTheme.accentColor
        copyButton.configuration = copyConfig
        copyButton.setTitle("Copy", for: .normal)
        buttonsStack.addArrangedSubview(copyButton)

        // Share button
        shareButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        shareButton.layer.cornerRadius = 6
        shareButton.clipsToBounds = true
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        if let icon = UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))?.withRenderingMode(.alwaysTemplate) {
            shareButton.setImage(icon, for: .normal)
        }
        var shareConfig = UIButton.Configuration.plain()
        shareConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        shareConfig.imagePadding = 5
        shareConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var attr = attr
            attr.font = .systemFont(ofSize: 11, weight: .semibold)
            return attr
        }
        shareConfig.baseForegroundColor = DebugTheme.accentColor
        shareButton.configuration = shareConfig
        shareButton.setTitle("Share", for: .normal)
        buttonsStack.addArrangedSubview(shareButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            cardView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            buttonsStack.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 14),
            buttonsStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            buttonsStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            buttonsStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
            buttonsStack.heightAnchor.constraint(equalToConstant: 36),
        ])
        view.forceLTR()
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = curlString

        let originalTitle = copyButton.title(for: .normal)
        copyButton.setTitle("Copied!", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setTitle(originalTitle, for: .normal)
        }
    }

    @objc private func shareTapped() {
        let activity = UIActivityViewController(activityItems: [curlString], applicationActivities: nil)
        if UIDevice.current.userInterfaceIdiom == .pad {
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0
            )
        }
        present(activity, animated: true)
    }

    // MARK: - cURL Syntax Highlighting

    private func highlightCurl(_ text: String) -> NSAttributedString {
        let font = UIFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: 0.82, alpha: 1)
        ])

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let flagColor = UIColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 1)       // blue
        let urlColor = UIColor(red: 0.26, green: 0.83, blue: 0.35, alpha: 1)        // green
        let stringColor = UIColor(red: 0.82, green: 0.60, blue: 0.34, alpha: 1)     // orange
        let cmdColor = UIColor(red: 0.70, green: 0.50, blue: 0.88, alpha: 1)        // purple

        // "curl" command keyword
        if let regex = try? NSRegularExpression(pattern: "^curl\\b", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: cmdColor, range: match.range)
                attr.addAttribute(.font, value: UIFont(name: "Menlo-Bold", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .bold), range: match.range)
            }
        }

        // Flags: -X, -H, -d, --data-binary
        if let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(-X|-H|-d|--data-binary)\\b", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: flagColor, range: match.range(at: 1))
            }
        }

        // Single-quoted strings: '...'
        if let regex = try? NSRegularExpression(pattern: "'[^']*'", options: []) {
            for match in regex.matches(in: text, range: fullRange) {
                let matchStr = nsText.substring(with: match.range)
                if matchStr.contains("://") {
                    attr.addAttribute(.foregroundColor, value: urlColor, range: match.range)
                } else {
                    attr.addAttribute(.foregroundColor, value: stringColor, range: match.range)
                }
            }
        }

        // Line continuation backslash
        if let regex = try? NSRegularExpression(pattern: "\\\\$", options: .anchorsMatchLines) {
            for match in regex.matches(in: text, range: fullRange) {
                attr.addAttribute(.foregroundColor, value: UIColor(white: 0.40, alpha: 1), range: match.range)
            }
        }

        return attr
    }
}
