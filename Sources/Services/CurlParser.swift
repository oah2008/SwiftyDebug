//
//  CurlParser.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import Foundation

/// Why a pasted cURL command could not be turned into a request.
enum CurlParseError: Error, Equatable, LocalizedError {
    case emptyInput
    case notACurlCommand
    /// The command ends inside an unclosed `'` or `"`.
    case unterminatedQuote(String)
    case danglingEscape
    case missingValue(flag: String)
    case missingURL
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Nothing to parse yet."
        case .notACurlCommand:
            return "No `curl` command found."
        case .unterminatedQuote(let quote):
            return "Unterminated \(quote == "'" ? "single" : "double") quote."
        case .danglingEscape:
            return "Command ends with a stray backslash."
        case .missingValue(let flag):
            return "`\(flag)` is missing its value."
        case .missingURL:
            return "No URL in the command."
        case .invalidURL(let raw):
            return "`\(raw)` is not a usable URL."
        }
    }
}

/// Turns a cURL command line into a `ParsedCurlRequest`.
///
/// The command is lexed the way a POSIX shell would (quote states, escapes,
/// backslash-newline continuations) and only then interpreted. A regex cannot
/// survive what real commands contain — JSON bodies full of braces and spaces,
/// `'\''`-escaped quotes, values that themselves start with a dash.
///
/// Unknown flags never fail the parse: they are consumed and reported in
/// `ignoredFlags` so the developer can see exactly what was dropped.
enum CurlParser {

    // MARK: - Entry point

    static func parse(_ command: String) throws -> ParsedCurlRequest {
        let tokens = try tokenize(command)
        guard !tokens.isEmpty else { throw CurlParseError.emptyInput }
        guard let curlIndex = tokens.firstIndex(where: { isCurlExecutable($0) }) else {
            throw CurlParseError.notACurlCommand
        }

        var builder = Builder()
        try builder.consume(Array(tokens[tokens.index(after: curlIndex)...]))
        return try builder.build()
    }

    /// `curl`, `/usr/bin/curl`, `curl.exe` — anything in front of it (a `$` prompt,
    /// a `time` prefix, a pipeline) is dropped rather than failing the parse.
    private static func isCurlExecutable(_ token: String) -> Bool {
        let name = (token as NSString).lastPathComponent.lowercased()
        return name == "curl" || name == "curl.exe"
    }

    // MARK: - Lexer

    /// Splits a shell command into words: single quotes are literal, double quotes
    /// honour only the escapes bash honours, backslash-newline is a line
    /// continuation, and adjacent quoted runs concatenate into a single word
    /// (which is what makes `'it'\''s'` come back as `it's`).
    static func tokenize(_ input: String) throws -> [String] {
        let chars = Array(input)
        var tokens: [String] = []
        var current = ""
        var started = false     // a word may legitimately be empty (`''`)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            switch c {
            // `isNewline` rather than "\n"/"\r": Swift folds CRLF into a single
            // Character, and Windows-pasted commands are full of them.
            case let space where space == " " || space == "\t" || space.isNewline:
                if started {
                    tokens.append(current)
                    current = ""
                    started = false
                }
                i += 1

            case "#" where !started:
                // Shell comment — only when it opens a word. SwiftyDebug's own
                // generator emits `# Binary body: 12 KB (not included)`.
                while i < chars.count, !chars[i].isNewline { i += 1 }

            // ANSI-C quoting: `$'...'`. Chrome and Firefox "Copy as cURL" switch to
            // this form the moment a header or body contains a non-ASCII character
            // or a newline, so without it the most common source of pasted commands
            // parses into garbage — a literal `$` followed by an escaped string.
            case "$" where i + 1 < chars.count && chars[i + 1] == "'":
                started = true
                i += 2
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "'" { closed = true; i += 1; break }
                    if d == "\\", i + 1 < chars.count {
                        let (text, consumed) = Self.ansiCEscape(chars, at: i + 1)
                        current.append(text)
                        i += 1 + consumed
                        continue
                    }
                    current.append(d)
                    i += 1
                }
                if !closed { throw CurlParseError.unterminatedQuote("'") }

            case "'":
                started = true
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "'" { closed = true; i += 1; break }
                    current.append(chars[i])
                    i += 1
                }
                if !closed { throw CurlParseError.unterminatedQuote("'") }

            case "\"":
                started = true
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\"" { closed = true; i += 1; break }
                    if d == "\\", i + 1 < chars.count {
                        let next = chars[i + 1]
                        // Inside double quotes bash only honours these four escapes;
                        // every other backslash stays literal — JSON bodies rely on it.
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                            i += 2
                            continue
                        }
                        if next.isNewline { i += 2; continue }
                        current.append(d)
                        i += 1
                        continue
                    }
                    current.append(d)
                    i += 1
                }
                if !closed { throw CurlParseError.unterminatedQuote("\"") }

            case "\\":
                guard i + 1 < chars.count else { throw CurlParseError.danglingEscape }
                let next = chars[i + 1]
                if next.isNewline {
                    i += 2                      // line continuation, word keeps going
                } else {
                    current.append(next)
                    started = true
                    i += 2
                }

            default:
                current.append(c)
                started = true
                i += 1
            }
        }

        if started { tokens.append(current) }
        return tokens
    }

    /// Decodes one escape sequence inside a `$'...'` string, starting at the
    /// character **after** the backslash. Returns the text it produces and how
    /// many characters it consumed.
    ///
    /// Unknown sequences yield the backslash and the character verbatim, matching
    /// bash — dropping them would silently corrupt a pasted body.
    static func ansiCEscape(_ chars: [Character], at index: Int) -> (String, Int) {
        guard index < chars.count else { return ("\\", 0) }
        let c = chars[index]
        switch c {
        case "n":  return ("\n", 1)
        case "t":  return ("\t", 1)
        case "r":  return ("\r", 1)
        case "a":  return ("\u{07}", 1)
        case "b":  return ("\u{08}", 1)
        case "f":  return ("\u{0C}", 1)
        case "v":  return ("\u{0B}", 1)
        case "e", "E": return ("\u{1B}", 1)
        case "\\": return ("\\", 1)
        case "'":  return ("'", 1)
        case "\"": return ("\"", 1)
        case "?":  return ("?", 1)
        case "x":
            // \xHH — one or two hex digits.
            var hex = ""
            var n = 1
            while n <= 2, index + n < chars.count, chars[index + n].isHexDigit {
                hex.append(chars[index + n]); n += 1
            }
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                return ("\\x", 1)
            }
            return (String(Character(scalar)), n)
        case "u", "U":
            // \uHHHH / \UHHHHHHHH — this is what carries the non-ASCII characters
            // that made the browser choose $'...' in the first place.
            let maxDigits = (c == "u") ? 4 : 8
            var hex = ""
            var n = 1
            while n <= maxDigits, index + n < chars.count, chars[index + n].isHexDigit {
                hex.append(chars[index + n]); n += 1
            }
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                return ("\\\(c)", 1)
            }
            return (String(Character(scalar)), n)
        case "0"..."7":
            // \nnn — up to three octal digits.
            var oct = ""
            var n = 0
            while n < 3, index + n < chars.count, ("0"..."7").contains(chars[index + n]) {
                oct.append(chars[index + n]); n += 1
            }
            guard let v = UInt32(oct, radix: 8), let scalar = Unicode.Scalar(v) else {
                return ("\\", 1)
            }
            return (String(Character(scalar)), n)
        default:
            return ("\\\(c)", 1)
        }
    }

    // MARK: - Argument interpretation

    private struct Builder {

        /// Short options that consume a value: either the rest of their cluster
        /// (`-XPOST`) or the next word (`-X POST`).
        private static let shortValueOptions: Set<Character> = [
            "X", "H", "d", "F", "u", "b", "A", "e", "T",            // acted on
            "o", "w", "x", "m", "E", "r", "D", "U", "C", "y", "Y",  // consumed only
            "z", "K", "Q", "P", "t", "c",
        ]

        /// Long options we do not act on but that still swallow their argument.
        /// Without this list `-o out.json` would leave `out.json` looking like the URL.
        private static let longValueOptions: Set<String> = [
            "output", "write-out", "proxy", "proxy-user", "connect-timeout", "max-time",
            "max-redirs", "max-filesize", "retry", "retry-delay", "retry-max-time",
            "cacert", "capath", "cert", "cert-type", "key", "key-type", "pass",
            "resolve", "interface", "limit-rate", "dump-header", "trace", "trace-ascii",
            "cookie-jar", "range", "unix-socket", "local-port", "login-options",
            "noproxy", "pinnedpubkey", "proto", "pubkey", "stderr", "socks5",
            "netrc-file", "engine", "krb", "libcurl", "tlsuser", "tlspassword",
        ]

        var explicitMethod: String?
        var urlString: String?
        var headers: [CurlHeader] = []
        var dataParts: [String] = []
        var formFields: [CurlFormField] = []
        var isGetFlag = false
        var isHeadFlag = false
        var hasUploadFile = false
        var followsRedirects = false
        var allowsInsecureTLS = false
        var wantsCompressed = false
        var ignored: [String] = []

        private var args: [String] = []
        private var index = 0

        // MARK: Walk

        mutating func consume(_ tokens: [String]) throws {
            args = tokens
            index = 0
            var positionalsOnly = false

            while index < args.count {
                let arg = args[index]
                if positionalsOnly || arg == "-" || !arg.hasPrefix("-") {
                    addPositional(arg)
                } else if arg == "--" {
                    positionalsOnly = true
                } else if arg.hasPrefix("--") {
                    try handleLong(arg)
                } else {
                    try handleShortCluster(arg)
                }
                index += 1
            }
        }

        private mutating func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw CurlParseError.missingValue(flag: flag) }
            return args[index]
        }

        private mutating func handleLong(_ arg: String) throws {
            let stripped = String(arg.dropFirst(2))
            var name = stripped
            var inlineValue: String?
            if let equals = stripped.firstIndex(of: "=") {
                name = String(stripped[..<equals])
                inlineValue = String(stripped[stripped.index(after: equals)...])
            }

            func value() throws -> String {
                if let inlineValue { return inlineValue }
                return try nextValue(for: "--" + name)
            }

            switch name {
            case "request":
                explicitMethod = try value()
            case "url":
                urlString = try value()
            case "header":
                addHeader(try value())
            case "data", "data-ascii":
                addData(try value(), stripNewlines: true, allowsFile: true)
            case "data-binary":
                addData(try value(), stripNewlines: false, allowsFile: true)
            case "data-raw":
                addData(try value(), stripNewlines: false, allowsFile: false)
            case "data-urlencode":
                addURLEncodedData(try value())
            case "json":
                // curl 7.82+: raw body plus JSON content negotiation.
                addData(try value(), stripNewlines: false, allowsFile: false)
                upsertHeader("Content-Type", "application/json")
                upsertHeader("Accept", "application/json")
            case "form":
                addForm(try value(), literal: false)
            case "form-string":
                addForm(try value(), literal: true)
            case "user":
                upsertHeader("Authorization", CurlParser.basicAuthValue(try value()))
            case "oauth2-bearer":
                upsertHeader("Authorization", "Bearer " + (try value()))
            case "cookie":
                addCookie(try value(), flag: "--cookie")
            case "user-agent":
                upsertHeader("User-Agent", try value())
            case "referer":
                upsertHeader("Referer", CurlParser.strippedReferer(try value()))
            case "head":
                isHeadFlag = true
            case "get":
                isGetFlag = true
            case "compressed":
                wantsCompressed = true
            case "location", "location-trusted":
                followsRedirects = true
            case "insecure":
                allowsInsecureTLS = true
            case "upload-file":
                let path = try value()
                hasUploadFile = true
                ignored.append("--upload-file \(path) (file not readable from the app)")
            default:
                if Self.longValueOptions.contains(name) {
                    let consumed = (try? value()) ?? ""
                    ignored.append(consumed.isEmpty ? arg : "--\(name) \(consumed)")
                } else {
                    ignored.append(arg)
                }
            }
        }

        private mutating func handleShortCluster(_ arg: String) throws {
            let chars = Array(arg.dropFirst())
            var i = 0
            while i < chars.count {
                let flag = chars[i]
                if Self.shortValueOptions.contains(flag) {
                    // `-XPOST` is legal curl: the rest of the cluster is the value.
                    let rest = String(chars[(i + 1)...])
                    let value = rest.isEmpty ? try nextValue(for: "-\(flag)") : rest
                    applyShort(flag, value: value)
                    return
                }
                applyShortBoolean(flag)
                i += 1
            }
        }

        private mutating func applyShort(_ flag: Character, value: String) {
            switch flag {
            case "X": explicitMethod = value
            case "H": addHeader(value)
            case "d": addData(value, stripNewlines: true, allowsFile: true)
            case "F": addForm(value, literal: false)
            case "u": upsertHeader("Authorization", CurlParser.basicAuthValue(value))
            case "b": addCookie(value, flag: "-b")
            case "A": upsertHeader("User-Agent", value)
            case "e": upsertHeader("Referer", CurlParser.strippedReferer(value))
            case "T":
                hasUploadFile = true
                ignored.append("-T \(value) (file not readable from the app)")
            default:
                ignored.append("-\(flag) \(value)")
            }
        }

        private mutating func applyShortBoolean(_ flag: Character) {
            switch flag {
            case "G": isGetFlag = true
            case "I": isHeadFlag = true
            case "L": followsRedirects = true
            case "k": allowsInsecureTLS = true
            default:  ignored.append("-\(flag)")
            }
        }

        // MARK: Pieces

        private mutating func addPositional(_ value: String) {
            if urlString == nil {
                urlString = value
            } else {
                // curl would fetch every URL given; we replay the first one.
                ignored.append("\(value) (extra URL)")
            }
        }

        /// `-H 'Name: value'`. `-H 'Name;'` is curl's syntax for an empty header.
        private mutating func addHeader(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            if let colon = trimmed.firstIndex(of: ":") {
                let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { ignored.append("-H \(raw)"); return }
                headers.append(CurlHeader(name: name, value: value))
            } else if trimmed.hasSuffix(";") {
                headers.append(CurlHeader(name: String(trimmed.dropLast()), value: ""))
            } else {
                ignored.append("-H \(raw)")
            }
        }

        private mutating func upsertHeader(_ name: String, _ value: String) {
            headers = CurlParser.upserting(name, value, in: headers)
        }

        private mutating func addCookie(_ value: String, flag: String) {
            // Without `=` curl reads the value as a cookie *file*, which we cannot open.
            guard value.contains("=") else {
                ignored.append("\(flag) \(value) (cookie file not readable from the app)")
                return
            }
            if let existing = headers.first(where: { $0.name.lowercased() == "cookie" })?.value,
               !existing.isEmpty {
                upsertHeader("Cookie", existing + "; " + value)
            } else {
                upsertHeader("Cookie", value)
            }
        }

        private mutating func addData(_ value: String, stripNewlines: Bool, allowsFile: Bool) {
            if allowsFile, value.hasPrefix("@") {
                ignored.append("--data \(value) (file not readable from the app)")
                return
            }
            // -d/--data drop CR/LF; --data-raw and --data-binary send bytes verbatim.
            let cleaned = stripNewlines
                ? value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                : value
            dataParts.append(cleaned)
        }

        /// `--data-urlencode` forms: `content`, `=content`, `name=content`,
        /// and the two file forms we cannot honour.
        private mutating func addURLEncodedData(_ value: String) {
            if let equals = value.firstIndex(of: "=") {
                let name = String(value[..<equals])
                let content = String(value[value.index(after: equals)...])
                let encoded = CurlParser.percentEncoded(content)
                dataParts.append(name.isEmpty ? encoded : "\(name)=\(encoded)")
                return
            }
            if value.contains("@") {
                ignored.append("--data-urlencode \(value) (file not readable from the app)")
                return
            }
            dataParts.append(CurlParser.percentEncoded(value))
        }

        private mutating func addForm(_ value: String, literal: Bool) {
            guard var field = CurlParser.parseFormField(value, literal: literal) else {
                ignored.append("-F \(value)")
                return
            }
            if field.filename != nil {
                // The sender's filesystem is not ours — keep the part, drop the bytes.
                ignored.append("-F \(value) (file not readable from the app)")
                field.value = ""
            }
            formFields.append(field)
        }

        // MARK: Result

        func build() throws -> ParsedCurlRequest {
            var finalHeaders = headers
            var body: Data?

            if !formFields.isEmpty {
                let boundary = "SwiftyDebugBoundary\(UUID().uuidString)"
                body = CurlParser.multipartBody(fields: formFields, boundary: boundary)
                finalHeaders = CurlParser.upserting(
                    "Content-Type", "multipart/form-data; boundary=\(boundary)", in: finalHeaders
                )
            } else if !isGetFlag, !dataParts.isEmpty {
                // Repeated -d flags are concatenated with `&`, exactly like curl.
                body = dataParts.joined(separator: "&").data(using: .utf8)
            }

            return ParsedCurlRequest(
                method: resolvedMethod(hasBody: body != nil),
                url: try resolvedURL(),
                headers: finalHeaders,
                body: body,
                ignoredFlags: ignored,
                followsRedirects: followsRedirects,
                allowsInsecureTLS: allowsInsecureTLS,
                wantsCompressedResponse: wantsCompressed
            )
        }

        private func resolvedMethod(hasBody: Bool) -> String {
            if let explicitMethod, !explicitMethod.isEmpty { return explicitMethod.uppercased() }
            if isHeadFlag { return "HEAD" }
            if hasUploadFile { return "PUT" }
            if isGetFlag { return "GET" }
            return hasBody ? "POST" : "GET"
        }

        private func resolvedURL() throws -> URL {
            guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw CurlParseError.missingURL
            }

            // A scheme-less host is http:// to curl, but App Transport Security
            // blocks cleartext on iOS — https is the only replayable guess.
            var string = raw.contains("://") ? raw : "https://" + raw

            if isGetFlag, !dataParts.isEmpty {
                // -G moves every -d payload into the query string.
                string += (string.contains("?") ? "&" : "?") + dataParts.joined(separator: "&")
            }

            guard let url = URL(string: string) ?? URL(string: CurlParser.sanitizedURLString(string)),
                  let host = url.host, !host.isEmpty else {
                throw CurlParseError.invalidURL(raw)
            }
            return url
        }
    }

    // MARK: - Shared helpers

    static func upserting(_ name: String, _ value: String, in headers: [CurlHeader]) -> [CurlHeader] {
        var result = headers
        if let index = result.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            result[index].value = value
        } else {
            result.append(CurlHeader(name: name, value: value))
        }
        return result
    }

    /// `-u user:pass` → `Basic base64(user:pass)`. curl prompts when the colon is
    /// missing; we cannot, so the password is empty.
    static func basicAuthValue(_ credentials: String) -> String {
        let normalized = credentials.contains(":") ? credentials : credentials + ":"
        return "Basic " + Data(normalized.utf8).base64EncodedString()
    }

    /// `-e 'https://site;auto'` — the `;auto` suffix is a curl directive, not part
    /// of the referer.
    static func strippedReferer(_ value: String) -> String {
        guard value.lowercased().hasSuffix(";auto") else { return value }
        return String(value.dropLast(5))
    }

    /// curl's `--data-urlencode` encoding: everything outside the unreserved set,
    /// with spaces as `%20` rather than `+`.
    static func percentEncoded(_ string: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Escapes the characters `URL(string:)` rejects while leaving already-encoded
    /// sequences and RFC 3986 delimiters intact.
    static func sanitizedURLString(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// `-F 'name=value;type=text/plain'`, `-F 'file=@/tmp/a.png'`.
    static func parseFormField(_ raw: String, literal: Bool) -> CurlFormField? {
        guard let equals = raw.firstIndex(of: "=") else { return nil }
        let name = String(raw[..<equals])
        guard !name.isEmpty else { return nil }

        var content = String(raw[raw.index(after: equals)...])
        var filename: String?
        var contentType: String?

        if !literal {
            let pieces = content.components(separatedBy: ";")
            content = pieces.first ?? ""
            for piece in pieces.dropFirst() {
                let modifier = piece.trimmingCharacters(in: .whitespaces)
                if modifier.hasPrefix("type=") {
                    contentType = String(modifier.dropFirst("type=".count))
                } else if modifier.hasPrefix("filename=") {
                    filename = String(modifier.dropFirst("filename=".count))
                } else {
                    content += ";" + piece      // not a modifier — it belonged to the value
                }
            }

            if content.hasPrefix("@") || content.hasPrefix("<") {
                let path = String(content.dropFirst())
                filename = filename ?? (path as NSString).lastPathComponent
                content = ""
            }
        }

        return CurlFormField(name: name, value: content, filename: filename, contentType: contentType)
    }

    static func multipartBody(fields: [CurlFormField], boundary: String) -> Data {
        var body = Data()
        for field in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(field.name)\""
            if let filename = field.filename {
                disposition += "; filename=\"\(filename)\""
            }
            body.append(Data((disposition + "\r\n").utf8))
            if let contentType = field.contentType {
                body.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(Data(field.value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
