import Foundation
import ReqlingKit
import XCTest

final class URLAbbreviatedPathTests: XCTestCase {
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    func testShortensPathsUnderTheHomeFolder() {
        let url = home.appendingPathComponent("Library/Application Support/Projects/api.reqling", isDirectory: true)

        XCTAssertEqual(url.abbreviatedPath, "~/Library/Application Support/Projects/api.reqling")
    }

    func testShortensTheHomeFolderItself() {
        XCTAssertEqual(home.abbreviatedPath, "~")
    }

    func testLeavesPathsOutsideTheHomeFolderAlone() {
        XCTAssertEqual(URL(fileURLWithPath: "/opt/homebrew/bin/protoc").abbreviatedPath, "/opt/homebrew/bin/protoc")
    }
}
