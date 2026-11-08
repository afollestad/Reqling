import Foundation
import XCTest

@testable import ReqlingKit

final class SecretRedactionTests: XCTestCase {
    private func redaction(_ secrets: [String: String]) -> SecretRedaction {
        let entries = secrets.mapValues { VariableScope.Entry(value: $0, source: .override, isSecret: true) }
        return SecretRedaction(resolver: TemplateResolver(scope: VariableScope(entries: entries)))
    }

    /// A redirecting server re-encodes a value its own way; `encodeURIComponent` keeps `!` but escapes `@`.
    func testAFinalURLMasksSecretsHowEverTheServerEncodedThem() throws {
        let redaction = redaction(["key": "p@ss!word"])
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/p%40ss!word/items?key=p%40ss!word&page=2&q=a+b"))

        let masked = redaction.apply(to: url)

        XCTAssertFalse(masked.contains("ss!word"))
        XCTAssertFalse(masked.removingPercentEncoding?.contains("p@ss!word") ?? true)
        XCTAssertTrue(masked.hasPrefix("https://api.example.com/v1/"))
        XCTAssertTrue(masked.hasSuffix("?key=\(TemplateResolver.mask)&page=2&q=a+b"))
    }

    /// Masking scans for where a value may start rather than searching once per value; it must mask exactly what that
    /// search would, whatever the case, overlap, encoding, or characters.
    func testMaskingMatchesSearchingForEveryValue() {
        let secrets = [
            "a": "Tok3n-Value", "b": "tok3n", "c": "p@ss word", "d": "ünïcode-key", "e": "kelvin-key", "f": "api.internal:8443",
            "g": "xyz", "h": "•••mask"
        ]
        let redaction = redaction(secrets)
        let texts = [
            "Bearer TOK3N-VALUE and tok3n-value", "a short tok3n", "p%40ss%20word and p@ss+word", "ÜNÏCODE-KEY sent",
            "\u{212A}elvin-key folds to kelvin-key", "dial API.INTERNAL:8443 then", "xy", "XYZ xyz Xy", "•••MASK", "nothing here",
            "tok3n-Value tok3n-valuE", ""
        ]

        for text in texts {
            let searched = redaction.values.reduce(text) {
                $0.replacingOccurrences(of: $1, with: TemplateResolver.mask, options: .caseInsensitive)
            }
            XCTAssertEqual(redaction.apply(text), searched, text)
        }
        XCTAssertEqual(redaction.apply("Bearer TOK3N-VALUE"), "Bearer \(TemplateResolver.mask)")
    }

    func testOnlyHostLikeSecretsMaskTheirHost() {
        let redaction = redaction(["a": "pw@server", "b": "prod/xyz", "c": "admin:secret", "d": "api.internal:8443/v1"])

        XCTAssertEqual(
            redaction.apply("A server with the specified hostname could not be found at /products by admin."),
            "A server with the specified hostname could not be found at /products by admin."
        )
        XCTAssertEqual(redaction.apply("Could not reach API.INTERNAL."), "Could not reach \(TemplateResolver.mask).")
    }
}
