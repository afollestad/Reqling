import Foundation
import ReqlingKit
import XCTest

/// Return in a YAML editor, with the cursor at the end of the text: YAML's `|` is a block scalar, not a cursor.
extension CodeIndentTests {
    private func yamlReturn(_ text: String) -> String? {
        CodeIndent.newline(in: text, at: (text as NSString).length, language: .yaml)?.replacement
    }

    func testYAMLKeepsTheLinesIndentation() {
        XCTAssertEqual(yamlReturn("a: 1"), "\n")
        XCTAssertEqual(yamlReturn("a:\n  b: 2"), "\n  ")
        XCTAssertEqual(yamlReturn("list:\n  - apple"), "\n  ")
        XCTAssertEqual(yamlReturn("note: \"a: #\""), "\n", "Inside quotes, neither the colon nor the hash counts")
    }

    func testYAMLGoesDeeperWhereABlockOpens() {
        XCTAssertEqual(yamlReturn("servers:"), "\n  ")
        XCTAssertEqual(yamlReturn("  paths:   # every route"), "\n    ")
        XCTAssertEqual(yamlReturn("description: |"), "\n  ")
        XCTAssertEqual(yamlReturn("- >-"), "\n  ")
        XCTAssertEqual(yamlReturn("  -"), "\n    ")
        XCTAssertEqual(yamlReturn("don't: # it's"), "\n  ", "An apostrophe inside a plain scalar opens no quote")
        XCTAssertEqual(yamlReturn("- key:"), "\n    ", "Under the item's key, not beside it")
        XCTAssertEqual(yamlReturn("  - - nested: |"), "\n        ")
        XCTAssertEqual(yamlReturn("  - - |"), "\n      ", "An item's own block scalar starts at the item's content")
    }
}
