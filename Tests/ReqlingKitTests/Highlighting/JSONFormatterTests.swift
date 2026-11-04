import ReqlingKit
import XCTest

final class JSONFormatterTests: XCTestCase {
    func testPreservesKeyOrderNumbersAndEscapes() {
        let pretty = JSONFormatter.pretty(#"{"z":1.50,"a":{"s":"x, \"y\" [z]","n":null},"e":[],"o":{},"l":[1,2]}"#)

        XCTAssertEqual(pretty, """
        {
          "z": 1.50,
          "a": {
            "s": "x, \\"y\\" [z]",
            "n": null
          },
          "e": [],
          "o": {},
          "l": [
            1,
            2
          ]
        }
        """)
    }

    func testReformatsAlreadyIndentedJSONAndRejectsNonJSON() {
        XCTAssertEqual(JSONFormatter.pretty("[\n\n  1 ,   2\n]"), "[\n  1,\n  2\n]")
        XCTAssertNil(JSONFormatter.pretty("hello"))
        XCTAssertNil(JSONFormatter.pretty("42"))
    }
}
