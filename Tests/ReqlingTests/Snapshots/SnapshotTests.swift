import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class SnapshotTests: XCTestCase {
    private let appInfo = AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling", version: "1.0.0", build: "1")

    func testContentView() {
        for colorScheme in [ColorScheme.light, .dark] {
            assertMacSnapshot(
                ContentView(appInfo: appInfo),
                size: CGSize(width: 720, height: 480),
                named: colorScheme == .dark ? "dark" : "light",
                colorScheme: colorScheme
            )
        }
    }
}
