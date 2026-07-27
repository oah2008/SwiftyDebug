//
//  CurlParserTests.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 25/07/2026.
//

import XCTest
@testable import SwiftyDebug

final class CurlParserTests: XCTestCase {

    // MARK: - Tokenizer

    func testTokenizerSplitsOnWhitespace() throws {
        let tokens = try CurlParser.tokenize("curl -X POST https://a.com")
        XCTAssertEqual(tokens, ["curl", "-X", "POST", "https://a.com"])
    }

    func testTokenizerKeepsSingleQuotedContentLiteral() throws {
        let tokens = try CurlParser.tokenize("curl -H 'Accept: */*; q=0.8'")
        XCTAssertEqual(tokens, ["curl", "-H", "Accept: */*; q=0.8"])
    }

    func testTokenizerHonoursDoubleQuoteEscapes() throws {
        let tokens = try CurlParser.tokenize("curl -d \"say \\\"hi\\\" now\"")
        XCTAssertEqual(tokens, ["curl", "-d", "say \"hi\" now"])
    }

    func testTokenizerKeepsUnknownBackslashesInsideDoubleQuotes() throws {
        // bash leaves \n literal inside double quotes — JSON bodies depend on it.
        let tokens = try CurlParser.tokenize("curl -d \"a\\nb\"")
        XCTAssertEqual(tokens, ["curl", "-d", "a\\nb"])
    }

    func testTokenizerConcatenatesAdjacentQuotedRuns() throws {
        let tokens = try CurlParser.tokenize("curl -H 'Content-Type: '\"application/json\"")
        XCTAssertEqual(tokens, ["curl", "-H", "Content-Type: application/json"])
    }

    func testTokenizerHandlesShellEscapedSingleQuote() throws {
        // '\'' is how POSIX shells embed a quote inside a single-quoted string.
        let tokens = try CurlParser.tokenize("curl -d 'it'\\''s here'")
        XCTAssertEqual(tokens, ["curl", "-d", "it's here"])
    }

    func testTokenizerJoinsLineContinuations() throws {
        let command = "curl -X POST \\\n  'https://a.com' \\\n  -H 'A: b'"
        XCTAssertEqual(try CurlParser.tokenize(command),
                       ["curl", "-X", "POST", "https://a.com", "-H", "A: b"])
    }

    func testTokenizerHandlesCarriageReturnLineContinuations() throws {
        let command = "curl \\\r\n  'https://a.com'"
        XCTAssertEqual(try CurlParser.tokenize(command), ["curl", "https://a.com"])
    }

    func testTokenizerSkipsComments() throws {
        let tokens = try CurlParser.tokenize("curl 'https://a.com' \\\n  # Binary body: 5 bytes (not included)\n-H 'A: b'")
        XCTAssertEqual(tokens, ["curl", "https://a.com", "-H", "A: b"])
    }

    func testTokenizerKeepsHashInsideAWord() throws {
        let tokens = try CurlParser.tokenize("curl https://a.com/x#frag")
        XCTAssertEqual(tokens, ["curl", "https://a.com/x#frag"])
    }

    // MARK: - Basics

    func testBareURLDefaultsToGET() throws {
        let request = try CurlParser.parse("curl https://api.example.com/users")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/users")
        XCTAssertTrue(request.headers.isEmpty)
        XCTAssertNil(request.body)
    }

    func testSchemelessURLBecomesHTTPS() throws {
        // ATS blocks cleartext on iOS, so a scheme-less host can only be replayed over https.
        let request = try CurlParser.parse("curl api.example.com/ping")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/ping")
    }

    func testURLFlagAndLeadingShellPromptAreAccepted() throws {
        let request = try CurlParser.parse("$ /usr/bin/curl --url 'https://api.example.com/v1'")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1")
    }

    func testBodyImpliesPOST() throws {
        let request = try CurlParser.parse("curl https://a.com -d 'x=1'")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.bodyString, "x=1")
    }

    func testExplicitMethodWinsOverInference() throws {
        let request = try CurlParser.parse("curl -X put https://a.com -d 'x=1'")
        XCTAssertEqual(request.method, "PUT")
    }

    func testAttachedShortOptionValue() throws {
        let request = try CurlParser.parse("curl -XDELETE https://a.com/items/4")
        XCTAssertEqual(request.method, "DELETE")
    }

    func testClusteredBooleanShortOptions() throws {
        let request = try CurlParser.parse("curl -sSLk https://a.com")
        XCTAssertTrue(request.followsRedirects)
        XCTAssertTrue(request.allowsInsecureTLS)
        XCTAssertEqual(request.ignoredFlags, ["-s", "-S"])
    }

    func testHeadFlagSetsHEAD() throws {
        let request = try CurlParser.parse("curl -I https://a.com")
        XCTAssertEqual(request.method, "HEAD")
    }

    // MARK: - Headers

    func testHeadersKeepOrderAndSplitOnFirstColonOnly() throws {
        let request = try CurlParser.parse("""
        curl 'https://a.com' \\
          -H 'Authorization: Bearer abc:def' \\
          -H 'X-Empty;' \\
          --header=Accept:application/json
        """)
        XCTAssertEqual(request.headers, [
            CurlHeader(name: "Authorization", value: "Bearer abc:def"),
            CurlHeader(name: "X-Empty", value: ""),
            CurlHeader(name: "Accept", value: "application/json"),
        ])
    }

    func testUserProducesBasicAuthHeader() throws {
        let request = try CurlParser.parse("curl -u user:pass https://a.com")
        XCTAssertEqual(request.value(forHeader: "authorization"), "Basic dXNlcjpwYXNz")
    }

    func testUserWithoutPasswordStillEncodesTheColon() throws {
        let request = try CurlParser.parse("curl --user admin https://a.com")
        XCTAssertEqual(request.value(forHeader: "Authorization"), "Basic " + Data("admin:".utf8).base64EncodedString())
    }

    func testUserAgentRefererAndCookieBecomeHeaders() throws {
        let request = try CurlParser.parse("curl -A 'MyApp/1.0' -e 'https://ref.com;auto' -b 'sid=1; theme=dark' https://a.com")
        XCTAssertEqual(request.value(forHeader: "User-Agent"), "MyApp/1.0")
        XCTAssertEqual(request.value(forHeader: "Referer"), "https://ref.com")
        XCTAssertEqual(request.value(forHeader: "Cookie"), "sid=1; theme=dark")
    }

    func testCookieFileIsIgnoredNotTreatedAsCookie() throws {
        let request = try CurlParser.parse("curl -b cookies.txt https://a.com")
        XCTAssertNil(request.value(forHeader: "Cookie"))
        XCTAssertEqual(request.ignoredFlags.count, 1)
    }

    // MARK: - Bodies

    func testJSONBodyWithSpacesAndBracesSurvivesIntact() throws {
        let json = "{\"filters\": {\"tags\": [\"a b\", \"c\"]}, \"page\": 0}"
        let request = try CurlParser.parse("curl -X POST 'https://a.com/search' -H 'Content-Type: application/json' --data-raw '\(json)'")
        XCTAssertEqual(request.bodyString, json)
        XCTAssertEqual(request.value(forHeader: "content-type"), "application/json")
    }

    func testRepeatedDataFlagsAreJoinedWithAmpersand() throws {
        let request = try CurlParser.parse("curl https://a.com -d 'a=1' -d 'b=2' --data 'c=3'")
        XCTAssertEqual(request.bodyString, "a=1&b=2&c=3")
    }

    func testDataStripsNewlinesButDataRawDoesNot() throws {
        let stripped = try CurlParser.parse("curl https://a.com -d 'line1\nline2'")
        XCTAssertEqual(stripped.bodyString, "line1line2")

        let verbatim = try CurlParser.parse("curl https://a.com --data-binary 'line1\nline2'")
        XCTAssertEqual(verbatim.bodyString, "line1\nline2")
    }

    func testDataFileReferenceIsIgnoredGracefully() throws {
        let request = try CurlParser.parse("curl https://a.com -d @payload.json")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.ignoredFlags, ["--data @payload.json (file not readable from the app)"])
    }

    func testDataURLEncodePercentEncodesTheValueOnly() throws {
        let request = try CurlParser.parse("curl https://a.com --data-urlencode 'q=hello world&x' --data-urlencode 'plain value'")
        XCTAssertEqual(request.bodyString, "q=hello%20world%26x&plain%20value")
    }

    func testJSONFlagSetsContentNegotiation() throws {
        let request = try CurlParser.parse("curl https://a.com --json '{\"a\":1}'")
        XCTAssertEqual(request.bodyString, "{\"a\":1}")
        XCTAssertEqual(request.value(forHeader: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHeader: "Accept"), "application/json")
    }

    func testFormFieldsBuildMultipartBody() throws {
        let request = try CurlParser.parse("curl https://a.com -F 'name=Jane Doe' -F 'note=hi;type=text/plain'")
        let contentType = try XCTUnwrap(request.value(forHeader: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = try XCTUnwrap(request.bodyString)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"name\"\r\n\r\nJane Doe"))
        XCTAssertTrue(body.contains("Content-Type: text/plain"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertEqual(request.method, "POST")
    }

    func testFormFileUploadKeepsThePartAndReportsIt() throws {
        let request = try CurlParser.parse("curl https://a.com -F 'avatar=@/tmp/me.png;type=image/png'")
        let body = try XCTUnwrap(request.bodyString)
        XCTAssertTrue(body.contains("name=\"avatar\"; filename=\"me.png\""))
        XCTAssertEqual(request.ignoredFlags.count, 1)
    }

    // MARK: - -G

    func testGetFlagMovesDataIntoTheQueryString() throws {
        let request = try CurlParser.parse("curl -G https://a.com/search -d 'q=shoes' -d 'page=2'")
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.url.absoluteString, "https://a.com/search?q=shoes&page=2")
    }

    func testGetFlagAppendsToAnExistingQueryString() throws {
        let request = try CurlParser.parse("curl -G 'https://a.com/search?lang=en' --data-urlencode 'q=red shoes'")
        XCTAssertEqual(request.url.absoluteString, "https://a.com/search?lang=en&q=red%20shoes")
        XCTAssertEqual(request.queryItems.map { $0.name }, ["lang", "q"])
        XCTAssertEqual(request.queryItems.last?.value, "red shoes")
    }

    // MARK: - Transport flags & unknown flags

    func testTransportFlagsAreCaptured() throws {
        let request = try CurlParser.parse("curl --compressed -L -k https://a.com")
        XCTAssertTrue(request.wantsCompressedResponse)
        XCTAssertTrue(request.followsRedirects)
        XCTAssertTrue(request.allowsInsecureTLS)
        XCTAssertTrue(request.ignoredFlags.isEmpty)
    }

    func testUnknownFlagsNeverFailTheParse() throws {
        let request = try CurlParser.parse("curl --totally-made-up https://a.com --retry 3 -o out.json")
        XCTAssertEqual(request.url.absoluteString, "https://a.com")
        XCTAssertEqual(request.ignoredFlags, ["--totally-made-up", "--retry 3", "-o out.json"])
    }

    func testValueTakingIgnoredFlagDoesNotSwallowTheURL() throws {
        // Without the known-value list, `out.json` would have been read as the URL.
        let request = try CurlParser.parse("curl -o out.json https://a.com/data")
        XCTAssertEqual(request.url.absoluteString, "https://a.com/data")
    }

    func testExtraURLsAreReportedNotUsed() throws {
        let request = try CurlParser.parse("curl https://a.com https://b.com")
        XCTAssertEqual(request.url.absoluteString, "https://a.com")
        XCTAssertEqual(request.ignoredFlags, ["https://b.com (extra URL)"])
    }

    // MARK: - Errors

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try CurlParser.parse("   \n ")) { error in
            XCTAssertEqual(error as? CurlParseError, .emptyInput)
        }
    }

    func testNonCurlCommandThrows() {
        XCTAssertThrowsError(try CurlParser.parse("wget https://a.com")) { error in
            XCTAssertEqual(error as? CurlParseError, .notACurlCommand)
        }
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try CurlParser.parse("curl 'https://a.com")) { error in
            XCTAssertEqual(error as? CurlParseError, .unterminatedQuote("'"))
        }
    }

    func testDanglingEscapeThrows() {
        XCTAssertThrowsError(try CurlParser.parse("curl https://a.com \\")) { error in
            XCTAssertEqual(error as? CurlParseError, .danglingEscape)
        }
    }

    func testMissingFlagValueThrows() {
        XCTAssertThrowsError(try CurlParser.parse("curl https://a.com -H")) { error in
            XCTAssertEqual(error as? CurlParseError, .missingValue(flag: "-H"))
        }
    }

    func testMissingURLThrows() {
        XCTAssertThrowsError(try CurlParser.parse("curl -X POST -H 'A: b'")) { error in
            XCTAssertEqual(error as? CurlParseError, .missingURL)
        }
    }

    func testHostlessURLThrows() {
        XCTAssertThrowsError(try CurlParser.parse("curl 'https://'")) { error in
            XCTAssertEqual(error as? CurlParseError, .invalidURL("https://"))
        }
    }

    // MARK: - Round-trip with SwiftyDebug's own generator

    func testRoundTripOfGeneratedCurl() throws {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/v1/users?page=2")
        model.method = "POST"
        model.requestHeaderFields = [
            "Authorization": "Bearer abc123",
            "Content-Type": "application/json",
            "Content-Length": "42",          // generator drops this one
            "Accept-Encoding": "gzip",       // and this one
        ] as NSDictionary
        let body = Data("{\"name\": \"Jane\", \"tags\": [\"a b\", \"c\"]}".utf8)

        let generated = model.cURLDescription(cachedRequestData: body)
        let parsed = try CurlParser.parse(generated)

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.url.absoluteString, "https://api.example.com/v1/users?page=2")
        XCTAssertEqual(parsed.bodyString, String(data: body, encoding: .utf8))
        XCTAssertEqual(parsed.headers, [
            CurlHeader(name: "Authorization", value: "Bearer abc123"),
            CurlHeader(name: "Content-Type", value: "application/json"),
        ])
        XCTAssertTrue(parsed.ignoredFlags.isEmpty)
    }

    func testRoundTripKeepsEmbeddedSingleQuotes() throws {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/v1/people")
        model.method = "POST"
        model.requestHeaderFields = ["Content-Type": "application/json"] as NSDictionary
        let raw = "{\"name\":\"O'Brien\",\"note\":\"it's fine\"}"

        let generated = model.cURLDescription(cachedRequestData: Data(raw.utf8))
        let parsed = try CurlParser.parse(generated)

        XCTAssertEqual(parsed.bodyString, raw)
    }

    /// The generator rewrites `Content-Type` when the body is JSON but the header
    /// claims otherwise — the parser has to see the rewritten value.
    func testRoundTripOfContentTypeFixup() throws {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/v1/items")
        model.method = "POST"
        model.requestHeaderFields = ["Content-Type": "application/x-www-form-urlencoded"] as NSDictionary

        let generated = model.cURLDescription(cachedRequestData: Data("{\"a\":1}".utf8))
        let parsed = try CurlParser.parse(generated)

        XCTAssertEqual(parsed.value(forHeader: "Content-Type"), "application/json")
    }

    /// The deliberate Algolia special case: `requests[].params` is expanded into
    /// real JSON keys before the command is written out.
    func testRoundTripOfAlgoliaParamsExpansion() throws {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://xyz-dsn.algolia.net/1/indexes/*/queries")
        model.method = "POST"
        model.requestHeaderFields = ["X-Algolia-API-Key": "key123"] as NSDictionary
        let original = "{\"requests\":[{\"indexName\":\"products\",\"params\":\"query=red%20shoes&page=0&facets=%5B%22brand%22%5D\"}]}"

        let generated = model.cURLDescription(cachedRequestData: Data(original.utf8))
        let parsed = try CurlParser.parse(generated)

        let body = try XCTUnwrap(parsed.bodyString)
        XCTAssertEqual(body, "{\"requests\":[{\"facets\":[\"brand\"],\"indexName\":\"products\",\"page\":0,\"query\":\"red shoes\"}]}")
        XCTAssertFalse(body.contains("\"params\""))
        XCTAssertEqual(parsed.value(forHeader: "X-Algolia-API-Key"), "key123")

        // And it is still valid JSON after the trip through the shell lexer.
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["requests"])
    }

    func testRoundTripOfBinaryBodyComment() throws {
        let model = NetworkTransaction()
        model.url = NSURL(string: "https://api.example.com/upload")
        model.method = "POST"
        model.requestHeaderFields = ["Content-Type": "image/jpeg"] as NSDictionary

        let generated = model.cURLDescription(cachedRequestData: Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]))
        XCTAssertTrue(generated.contains("# Binary body:"))

        let parsed = try CurlParser.parse(generated)
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertNil(parsed.body)
        XCTAssertEqual(parsed.value(forHeader: "Content-Type"), "image/jpeg")
    }

    // MARK: - Consumers

    func testMakeURLRequestCarriesEverything() throws {
        let request = try CurlParser.parse("curl -X PATCH 'https://a.com/x' -H 'A: 1' -H 'A: 2' --data-raw 'body'")
        let urlRequest = request.makeURLRequest()

        XCTAssertEqual(urlRequest.httpMethod, "PATCH")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://a.com/x")
        // Duplicate header names are appended, not replaced.
        let combined = try XCTUnwrap(urlRequest.value(forHTTPHeaderField: "A"))
        XCTAssertTrue(combined.contains("1") && combined.contains("2"))
        XCTAssertEqual(urlRequest.httpBody, Data("body".utf8))
        // curl's default when a body has no declared type.
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testMakeURLRequestKeepsDeclaredContentType() throws {
        let request = try CurlParser.parse("curl 'https://a.com' -H 'Content-Type: application/json' -d '{}'")
        XCTAssertEqual(request.makeURLRequest().value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testMakeInterceptRulePrefillsHeadersAndParams() throws {
        let request = try CurlParser.parse("curl 'https://a.com/api/users/42/orders?page=2&sort=asc' -H 'Authorization: Bearer x' -H 'Authorization: Bearer y'")

        let exact = request.makeInterceptRule(matchMode: .exact)
        XCTAssertEqual(exact.matchEndpoint, "/api/users/42/orders")
        XCTAssertEqual(exact.matchMode, .exact)
        // One value per key — the last occurrence wins, like curl's own resolution.
        XCTAssertEqual(exact.headerOverrides.map { $0.key }, ["Authorization"])
        XCTAssertEqual(exact.headerOverrides.first?.value, "Bearer y")
        XCTAssertEqual(exact.queryParamOverrides.map { $0.key }, ["page", "sort"])
        XCTAssertEqual(exact.queryParamOverrides.first?.value, "2")

        let pattern = request.makeInterceptRule(matchMode: .normalized)
        XCTAssertEqual(pattern.matchEndpoint, "/api/users/{id}/orders")

        let host = request.makeInterceptRule(matchMode: .host)
        XCTAssertEqual(host.matchHosts, ["a.com"])
    }

    func testMakeNetworkTransactionBridgesToTheSDKModel() throws {
        let request = try CurlParser.parse("curl -X POST 'https://a.com/x' -H 'A: 1' --data-raw 'hello'")
        let model = request.makeNetworkTransaction()

        XCTAssertEqual(model.method, "POST")
        XCTAssertEqual(model.url?.absoluteString, "https://a.com/x")
        XCTAssertEqual(model.requestHeaderFields?["A"] as? String, "1")
        XCTAssertEqual(model.requestData, Data("hello".utf8))
    }

    // MARK: - Real-world shapes

    func testChromeCopyAsCurlCommand() throws {
        let command = """
        curl 'https://api.example.com/graphql' \\
          -H 'accept: */*' \\
          -H 'accept-language: en-US,en;q=0.9' \\
          -H 'content-type: application/json' \\
          -H 'cookie: session=abc; theme=dark' \\
          --data-raw '{"operationName":"Search","variables":{"q":"a b"},"query":"query Search($q: String) { search(q: $q) { id } }"}' \\
          --compressed
        """
        let request = try CurlParser.parse(command)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers.count, 4)
        XCTAssertEqual(request.value(forHeader: "cookie"), "session=abc; theme=dark")
        XCTAssertTrue(request.wantsCompressedResponse)

        let body = try XCTUnwrap(request.bodyString)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(object?["operationName"] as? String, "Search")
    }

    // MARK: - ANSI-C quoting ($'...')

    // Browsers switch to $'...' the moment a value contains a newline or a
    // non-ASCII character, so this is the single most common paste source.

    func testAnsiCQuotedHeaderWithEscapedNewline() throws {
        let cmd = "curl 'https://a.com/x' -H $'X-Note: line1\\nline2'"
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "X-Note" }?.value, "line1\nline2")
    }

    func testAnsiCQuotedUnicodeEscape() throws {
        // é is exactly what Chrome emits for "é".
        let cmd = "curl 'https://a.com/x' -H $'X-Name: caf\\u00e9'"
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "X-Name" }?.value, "café")
    }

    func testAnsiCQuotedHexAndOctalEscapes() throws {
        let cmd = "curl 'https://a.com/x' -H $'A: \\x41' -H $'B: \\102'"
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "A" }?.value, "A")
        XCTAssertEqual(request.headers.first { $0.name == "B" }?.value, "B")
    }

    func testAnsiCQuotedEscapedQuoteAndBackslash() throws {
        let cmd = #"curl 'https://a.com/x' -H $'X: it\'s\\done'"#
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "X" }?.value, #"it's\done"#)
    }

    func testUnknownAnsiCEscapeIsKeptVerbatim() throws {
        // bash leaves an unrecognised escape alone; dropping it would corrupt a body.
        let cmd = "curl 'https://a.com/x' -H $'X: a\\qb'"
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "X" }?.value, #"a\qb"#)
    }

    func testBareDollarIsStillLiteral() throws {
        // Only `$'` opens an ANSI-C string — a lone $ must not change meaning.
        let cmd = "curl 'https://a.com/x' -H 'X-Cost: $5'"
        let request = try CurlParser.parse(cmd)
        XCTAssertEqual(request.headers.first { $0.name == "X-Cost" }?.value, "$5")
    }

    func testUnterminatedAnsiCStringIsRejected() {
        XCTAssertThrowsError(try CurlParser.parse("curl 'https://a.com' -H $'X: oops"))
    }
}
