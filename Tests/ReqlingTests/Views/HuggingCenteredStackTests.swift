import AppKit
import SwiftUI
import XCTest

@testable import Reqling

/// Measures as a toolbar does: offering more width than the lines need.
@MainActor
final class HuggingCenteredStackTests: XCTestCase {
    private func size(of view: some View, offered width: CGFloat = 400) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 200))
    }

    private func lines(_ first: String, _ second: String) -> some View {
        HuggingCenteredStack(maxWidth: 160) {
            Text(first)
            Text(second).font(.caption2)
        }
        .lineLimit(1)
    }

    func testItHugsItsWidestLineWhenOfferedMore() {
        let widest = size(of: Text("GraphQL Testing").font(.caption2)).width

        XCTAssertEqual(size(of: lines("Default", "GraphQL Testing")).width, widest, accuracy: 0.5)
        XCTAssertLessThan(widest, 160)
        // The measurement really offers extra room: a flexible frame, which this replaces, takes all of it.
        XCTAssertEqual(size(of: VStack { Text("Default"); Text("GraphQL Testing").font(.caption2) }.frame(maxWidth: 160)).width, 160)
    }

    func testItStopsAtItsMaximumAndStacksItsLines() {
        let long = size(of: lines("Default", "Acme Corporation Internal Platform Services API"))
        let single = size(of: Text("Default")).height

        XCTAssertEqual(long.width, 160)
        XCTAssertGreaterThan(long.height, single, "both lines stack")
        XCTAssertEqual(size(of: lines("Default", "Acme Corporation Internal Platform Services API"), offered: 100).width, 100)
    }
}
