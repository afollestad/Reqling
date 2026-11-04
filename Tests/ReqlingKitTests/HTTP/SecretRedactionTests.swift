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

    func testOnlyHostLikeSecretsMaskTheirHost() {
        let redaction = redaction(["a": "pw@server", "b": "prod/xyz", "c": "admin:secret", "d": "api.internal:8443/v1"])

        XCTAssertEqual(
            redaction.apply("A server with the specified hostname could not be found at /products by admin."),
            "A server with the specified hostname could not be found at /products by admin."
        )
        XCTAssertEqual(redaction.apply("Could not reach API.INTERNAL."), "Could not reach \(TemplateResolver.mask).")
    }
}
