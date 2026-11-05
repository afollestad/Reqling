import AppKit
import SwiftUI
import XCTest

@testable import Reqling

/// The info icon's contract without showing its popover, which live tests avoid on macOS 26 (`Tests/AGENTS.md`).
@MainActor
final class AppHoverInfoIconTests: XCTestCase {
    /// Inside a toggle row the icon sits in the row's button; a click must reach the icon, not flip the setting.
    func testAClickOnTheIconInAToggleRowReachesTheIcon() throws {
        let row = SettingsToggleRow("Check for updates automatically", helpText: "Checks GitHub every 6 hours.", isOn: .constant(true))
        let hosting = NSHostingView(rootView: row.frame(width: 480))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 80), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let icon = try XCTUnwrap(Self.infoButton(in: hosting))
        let center = icon.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: hosting.superview)

        XCTAssertTrue(hosting.hitTest(center) === icon, "The icon handles its own mouse events")
        XCTAssertEqual(icon.accessibilityValue() as? String, "Checks GitHub every 6 hours.")
        XCTAssertEqual(icon.accessibilityLabel(), "More information")
    }

    /// A richer popover, such as an example, still tells VoiceOver what it says, under the icon's own name.
    func testAnIconWithContentNamesItselfAndReadsItsSummary() throws {
        let icon = AppHoverInfoIcon(systemImage: "questionmark.circle", accessibilityLabel: "How it works", summary: "Use it like this.") {
            Text("An example")
        }
        let hosting = NSHostingView(rootView: icon)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(Self.infoButton(in: hosting))

        XCTAssertEqual(button.accessibilityLabel(), "How it works")
        XCTAssertEqual(button.accessibilityValue() as? String, "Use it like this.")
        XCTAssertNotNil(button.image)
    }

    /// It explains disabled settings too, so a disabled row leaves it working.
    func testADisabledRowLeavesTheIconEnabled() {
        let icon = AppKitHoverInfoButton()
        icon.isEnabled = false

        XCTAssertTrue(icon.isEnabled)
        XCTAssertEqual(icon.alphaValue, 1)
    }

    func testLongTextWrapsAndShortTextStaysOnOneLine() {
        XCTAssertFalse(AppHoverTooltipContent.wraps("Checks GitHub every 6 hours."))
        XCTAssertTrue(AppHoverTooltipContent.wraps(String(repeating: "A long explanation of a setting. ", count: 4)))
    }

    private static func infoButton(in view: NSView) -> AppKitHoverInfoButton? {
        if let button = view as? AppKitHoverInfoButton {
            return button
        }
        return view.subviews.lazy.compactMap { infoButton(in: $0) }.first
    }
}
