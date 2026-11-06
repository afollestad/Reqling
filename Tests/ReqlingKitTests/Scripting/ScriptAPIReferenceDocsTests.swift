import Foundation
@testable import ReqlingKit
import XCTest

/// `docs/scripts.md`'s API reference is the catalog's, so it never drifts from what runs. `RECORD_SCRIPT_REFERENCE=1`
/// rewrites it.
final class ScriptAPIReferenceDocsTests: XCTestCase {
    private static let start = "<!-- script-reference:start -->"
    private static let end = "<!-- script-reference:end -->"

    private var guide: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/scripts.md")
    }

    func testTheGuidesReferenceIsTheCatalogs() throws {
        let text = try String(contentsOf: guide, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: Self.start), "The guide needs \(Self.start)")
        let end = try XCTUnwrap(text.range(of: Self.end, range: start.upperBound..<text.endIndex), "The guide needs \(Self.end)")
        let expected = "\n\n" + ScriptAPICatalog.reference + "\n"
        if ProcessInfo.processInfo.environment["RECORD_SCRIPT_REFERENCE"] == "1" {
            try (String(text[..<start.upperBound]) + expected + String(text[end.lowerBound...])).write(to: guide, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(String(text[start.upperBound..<end.lowerBound]), expected, "Run with RECORD_SCRIPT_REFERENCE=1 to update docs/scripts.md")
    }
}
