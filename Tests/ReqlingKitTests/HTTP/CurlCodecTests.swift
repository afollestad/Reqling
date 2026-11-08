import Foundation
import ReqlingKit
import XCTest

final class CurlCodecTests: XCTestCase {
    func testImportsABrowserStyleCommand() throws {
        let command = #"""
        curl 'https://api.example.com/users?page=2&q=a%20b' \
          -H 'accept: application/json' \
          -H $'x-note: it\'s' \
          -H "Content-Type: application/json" \
          --data-raw '{"name":"Ada"}' \
          --compressed
        """#

        let imported = try CurlCodec.importCommand(command)

        XCTAssertEqual(imported.spec.method, .post)
        XCTAssertEqual(imported.spec.url, "https://api.example.com/users")
        XCTAssertEqual(
            imported.spec.queryParameters.unidentified,
            [KeyValuePair(key: "page", value: "2"), KeyValuePair(key: "q", value: "a%20b")].unidentified
        )
        XCTAssertEqual(
            imported.spec.headers.unidentified,
            [KeyValuePair(key: "accept", value: "application/json"), KeyValuePair(key: "x-note", value: "it's")].unidentified
        )
        XCTAssertEqual(imported.spec.body.mode, .raw)
        XCTAssertEqual(imported.spec.body.raw, RawBody(text: #"{"name":"Ada"}"#, contentType: "application/json"))
        XCTAssertTrue(imported.warnings.isEmpty)
    }

    func testAPathVariableSegmentGetsAnEmptyRow() throws {
        let imported = try CurlCodec.importCommand("curl 'https://api.example.com/users/:id?x=1'")

        XCTAssertEqual(imported.spec.url, "https://api.example.com/users/:id")
        XCTAssertEqual(imported.spec.pathVariables.unidentified, [KeyValuePair(key: "id", value: "")].unidentified)
    }

    func testBundledSwitchesAttachedValuesAndCurlDefaults() throws {
        let imported = try CurlCodec.importCommand("curl -sSLk -XPUT -uada:pw -d a=1 -d b=2 --max-time=5 example.com/x")

        XCTAssertEqual(imported.spec.method, .put)
        XCTAssertEqual(imported.spec.url, "example.com/x")
        XCTAssertEqual(imported.spec.auth, .basic(username: "ada", password: "pw"))
        XCTAssertEqual(imported.spec.body.raw, RawBody(text: "a=1&b=2", contentType: "application/x-www-form-urlencoded"))
        XCTAssertEqual(imported.spec.options, HTTPRequestOptions(timeoutSeconds: 5, followRedirects: true, verifyTLS: false))
    }

    func testGetMovesDataIntoTheQueryAndFormsBecomeFormData() throws {
        let get = try CurlCodec.importCommand("curl -G https://x/search -d q=swift --data-urlencode 'lang=en us'")
        let form = try CurlCodec.importCommand("curl https://x/upload -F name=Ada -F avatar=@photo.png")

        XCTAssertEqual(get.spec.method, .get)
        XCTAssertEqual(
            get.spec.queryParameters.unidentified,
            [KeyValuePair(key: "q", value: "swift"), KeyValuePair(key: "lang", value: "en us")].unidentified
        )
        XCTAssertEqual(form.spec.method, .post)
        XCTAssertEqual(
            form.spec.body.formData.unidentified,
            [MultipartField(key: "name", value: "Ada"), MultipartField(key: "avatar", kind: .file)].unidentified
        )
        XCTAssertEqual(form.warnings, ["Choose the file for the “avatar” form field."])
    }

    func testRejectsMalformedCommands() {
        XCTAssertThrowsError(try CurlCodec.importCommand("wget https://x")) { XCTAssertEqual($0 as? CurlImportError, .notACurlCommand) }
        XCTAssertThrowsError(try CurlCodec.importCommand("curl -H 'a: b'")) { XCTAssertEqual($0 as? CurlImportError, .missingURL) }
        XCTAssertThrowsError(try CurlCodec.importCommand("curl 'https://x")) { XCTAssertEqual($0 as? CurlImportError, .unterminatedQuote) }
        XCTAssertThrowsError(try CurlCodec.importCommand("curl https://x -H")) { XCTAssertEqual($0 as? CurlImportError, .missingValue("-H")) }
    }

    func testExportRoundTripsThroughImport() throws {
        let spec = HTTPRequestSpec(
            method: .patch,
            url: "https://x/it's",
            headers: [KeyValuePair(key: "X-A", value: "1")],
            body: .raw(#"{"a":"it's"}"#)
        )
        let prepared = try HTTPRequestBuilder.prepare(spec, context: HTTPBuildContext(
            resolver: TemplateResolver(scope: VariableScope()),
            authChain: [.none],
            paths: ProjectPathResolver(projectRoot: FileManager.default.temporaryDirectory),
            defaults: HTTPRequestDefaults(),
            userAgent: "Reqling/1.0"
        ))

        let command = CurlCodec.export(prepared)
        let reimported = try CurlCodec.importCommand(command)

        XCTAssertTrue(command.hasPrefix("curl -X PATCH 'https://x/it'\\''s'"))
        XCTAssertEqual(reimported.spec.method, .patch)
        XCTAssertEqual(reimported.spec.body.raw.text, #"{"a":"it's"}"#)
        XCTAssertTrue(reimported.spec.headers.contains(key: "X-A", value: "1"))
        XCTAssertEqual(reimported.spec.options.followRedirects, true)
    }

    func testMaskedExportHidesSecrets() throws {
        let prepared = try HTTPRequestBuilder.prepare(
            HTTPRequestSpec(url: "https://x", headers: [KeyValuePair(key: "Authorization", value: "Bearer {{token}}")]),
            context: HTTPBuildContext(
                resolver: TemplateResolver(scope: VariableScope(entries: ["token": .init(value: "s3cr3t", source: .override, isSecret: true)])),
                authChain: [.none],
                paths: ProjectPathResolver(projectRoot: FileManager.default.temporaryDirectory),
                defaults: HTTPRequestDefaults(),
                userAgent: "Reqling/1.0"
            )
        )

        XCTAssertFalse(CurlCodec.export(prepared, masked: true).contains("s3cr3t"))
        XCTAssertTrue(CurlCodec.export(prepared).contains("s3cr3t"))
    }

    func testANSIQuotingDecodesTheEscapesBrowsersWrite() throws {
        // Chrome writes `!` as `!`; Firefox writes "é" as `\xe9`.
        let chrome = try CurlCodec.importCommand(#"curl https://x --data-raw $'{"p":"Secret!","t":"a\tb"}'"#)
        XCTAssertEqual(chrome.spec.body.raw.text, "{\"p\":\"Secret!\",\"t\":\"a\tb\"}")

        let escapes = [#"caf\xe9"#, #"\xc3\xa9"#, #"\101\102"#, #"\0102"#, #"\U0001F600"#, #"\q"#, #"\x"#]
        let command = "curl https://x " + escapes.map { "-H $'X: \($0)'" }.joined(separator: " ")
        let decoded = try CurlCodec.importCommand(command).spec.headers.map(\.value)
        XCTAssertEqual(decoded, ["café", "é", "AB", "\u{08}2", "😀", #"\q"#, #"\x"#])
    }

    func testDataURLEncodeFormsAndMixingWithData() throws {
        let mixed = try CurlCodec.importCommand("curl https://x -d a=1 --data-urlencode 'q=x y' --data-urlencode 'raw text' --data-urlencode '=b&c'")
        XCTAssertEqual(mixed.spec.body.raw, RawBody(text: "a=1&q=x%20y&raw%20text&b%26c", contentType: "application/x-www-form-urlencoded"))
        XCTAssertEqual(mixed.spec.method, .post)

        let files = try CurlCodec.importCommand("curl https://x --data-urlencode name@name.txt --data-urlencode @all.txt")
        XCTAssertEqual(files.spec.body.urlEncoded.unidentified, [KeyValuePair(key: "name", value: "")].unidentified)
        XCTAssertEqual(files.warnings.count, 2)
    }

    func testDataURLEncodeEscapesLikeCurl() throws {
        let get = try CurlCodec.importCommand("curl -G https://x --data-urlencode 'v=100%41' --data-urlencode '50% off'")
        let url = try HTTPRequestBuilder.prepare(get.spec, context: HTTPBuildContext(
            resolver: TemplateResolver(scope: VariableScope()),
            authChain: [.none],
            paths: ProjectPathResolver(projectRoot: FileManager.default.temporaryDirectory),
            defaults: HTTPRequestDefaults(),
            userAgent: "Reqling/1.0"
        )).urlRequest.url

        XCTAssertEqual(url?.absoluteString, "https://x?v=100%2541&50%25%20off")
        // cURL sends a name as written, which a form table would re-encode, so it stays a raw body.
        let named = try CurlCodec.importCommand("curl https://x --data-urlencode 'a%20b=c d'")
        XCTAssertEqual(named.spec.body.raw.text, "a%20b=c%20d")
    }

    func testOptionsThatTakeValuesNeverSwallowTheURL() throws {
        let imported = try CurlCodec.importCommand(
            "curl -x http://proxy:8080 --cacert ca.pem -w '%{http_code}' --retry 3 -o out.json https://api.example.com/x"
        )

        XCTAssertEqual(imported.spec.url, "https://api.example.com/x")
        XCTAssertEqual(imported.warnings, ["Ignored the unsupported option -x.", "Ignored the unsupported option --cacert."])
        let more = [
            "--socks5-gssapi-service", "--proxy-service-name", "--ftp-method", "--pubkey", "--hostpubsha256", "--dns-interface", "--proxy-ciphers"
        ]
        let rest = try CurlCodec.importCommand("curl " + more.map { "\($0) value" }.joined(separator: " ") + " https://x")
        XCTAssertEqual(rest.spec.url, "https://x")
        XCTAssertEqual(rest.warnings.count, more.count)
    }

    func testJSONBundledShortOptionsAndOtherForms() throws {
        let json = try CurlCodec.importCommand(#"curl --json '{"a":1}' https://x"#)
        XCTAssertEqual(json.spec.method, .post)
        XCTAssertEqual(json.spec.body.raw, RawBody(text: #"{"a":1}"#, contentType: "application/json"))
        XCTAssertEqual(json.spec.headers.unidentified, [KeyValuePair(key: "Accept", value: "application/json")].unidentified)

        let bundled = try CurlCodec.importCommand("curl -sXPOST -sH 'X-A: 1' --oauth2-bearer t0k https://x")
        XCTAssertEqual(bundled.spec.method, .post)
        XCTAssertEqual(bundled.spec.headers.unidentified, [KeyValuePair(key: "X-A", value: "1")].unidentified)
        XCTAssertEqual(bundled.spec.auth, .bearer(token: "t0k"))
        XCTAssertTrue(bundled.warnings.isEmpty)

        let get = try CurlCodec.importCommand("curl -G https://x -d 'q=a+b'")
        XCTAssertEqual(get.spec.queryParameters.unidentified, [KeyValuePair(key: "q", value: "a b")].unidentified)
        XCTAssertEqual(try CurlCodec.importCommand("curl -I https://x").spec.method, .head)
        let literal = try CurlCodec.importCommand("curl https://x --form-string 'a=@b'")
        XCTAssertEqual(literal.spec.body.formData.unidentified, [MultipartField(key: "a", value: "@b")].unidentified)
    }

    func testWindowsLineContinuations() throws {
        let imported = try CurlCodec.importCommand("curl https://x \\\r\n  -H 'A: b' \\\r\n  -d \"one \\\r\ntwo\"")

        XCTAssertEqual(imported.spec.headers.unidentified, [KeyValuePair(key: "A", value: "b")].unidentified)
        XCTAssertEqual(imported.spec.body.raw.text, "one two")
        XCTAssertTrue(imported.warnings.isEmpty)
    }

    func testExportWithABinaryBodyStaysOneCommand() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data([0xFF, 0x00]).write(to: directory.file("blob.bin"))
        let spec = HTTPRequestSpec(method: .put, url: "https://x", body: HTTPBody(mode: .binary, binary: BinaryBody(file: .relative("blob.bin"))))
        let prepared = try HTTPRequestBuilder.prepare(spec, context: HTTPBuildContext(
            resolver: TemplateResolver(scope: VariableScope()),
            authChain: [.none],
            paths: ProjectPathResolver(projectRoot: directory.url),
            defaults: HTTPRequestDefaults(verifyTLS: false),
            userAgent: "Reqling/1.0"
        ))

        let command = CurlCodec.export(prepared)
        let reimported = try CurlCodec.importCommand(command)

        XCTAssertFalse(command.contains("#"))
        XCTAssertTrue(command.contains("--data-binary @body.bin"))
        XCTAssertEqual(reimported.spec.options.followRedirects, true)
        XCTAssertEqual(reimported.spec.options.verifyTLS, false)
    }
}
