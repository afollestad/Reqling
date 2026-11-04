import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class SnapshotTests: XCTestCase {
    var fixture: AppFixture!

    override func setUp() async throws {
        fixture = AppFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    /// Records a `light` and a `dark` baseline of `view`.
    func assertBothAppearances<V: View>(
        _ view: @autoclosure () -> V,
        size: CGSize,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        for colorScheme in [ColorScheme.light, .dark] {
            assertMacSnapshot(
                view(),
                size: size,
                named: colorScheme == .dark ? "dark" : "light",
                colorScheme: colorScheme,
                file: file,
                testName: testName,
                line: line
            )
        }
    }
}
