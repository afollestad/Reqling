@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// What a stream phase's helper is given and when, without a process.
final class ScriptStreamWindowTests: XCTestCase {
    private func item(_ number: Int, bytes: Int = 1) -> ScriptStreamItem {
        ScriptStreamItem(number: number, content: .grpcMessage(String(repeating: "x", count: bytes)))
    }

    func testItemsWaitForTheTopLevelThenGoOneAtATime() {
        var window = ScriptStreamWindow(limit: 10, byteLimit: 1_000)

        XCTAssertEqual(window.deliver(item(1)).1, .none, "The top level still runs")
        XCTAssertEqual(window.deliver(item(2)).1, .none)
        XCTAssertEqual(window.registered(handlers: 1), .write(item(1)))
        XCTAssertEqual(window.deliver(item(3)).1, .none, "Item 1 is in hand")
        XCTAssertEqual(window.finished(item: 1), .write(item(2)))
        XCTAssertEqual(window.finished(item: 2), .write(item(3)))
        XCTAssertEqual(window.finished(item: 3), .none)
        XCTAssertEqual(window.deliver(item(4)).1, .write(item(4)), "Nothing in hand, so it goes straight out")
        XCTAssertEqual(window.end(), .none, "Item 4 is still in hand")
        XCTAssertEqual(window.finished(item: 4), .closeInput)
        XCTAssertEqual(window.deliver(item(5)).0, .refused)
    }

    func testATopLevelWithNoHandlersNeedsNothingItReceives() {
        var window = ScriptStreamWindow(limit: 10, byteLimit: 1_000)
        _ = window.deliver(item(1))

        XCTAssertEqual(window.registered(handlers: 0), .closeInput)
        XCTAssertEqual(window.deliver(item(2)).0, .unneeded)
        XCTAssertEqual(window.over().abandoned, 0, "What waited needed no handler, so none was abandoned")
    }

    func testFallingBehindDropsTheOldestWaitingByCountAndBytesKeepingTheNewest() {
        var window = ScriptStreamWindow(limit: 2, byteLimit: 10)
        _ = window.registered(handlers: 1)
        _ = window.deliver(item(1))

        XCTAssertEqual(window.deliver(item(2)).0, .queued(dropped: 0))
        XCTAssertEqual(window.deliver(item(3)).0, .queued(dropped: 0))
        XCTAssertEqual(window.deliver(item(4)).0, .queued(dropped: 1), "Past two waiting, item 2 goes")
        XCTAssertEqual(window.deliver(item(5, bytes: 9)).0, .queued(dropped: 1), "Past ten bytes, item 3 goes")
        XCTAssertEqual(window.deliver(item(6, bytes: 20)).0, .queued(dropped: 2), "The newest stays, however large")
        XCTAssertEqual(window.finished(item: 1), .write(item(6, bytes: 20)))
    }

    func testStopDropsWhatWaitsAndClosesWhileTheCallInHandFinishes() {
        var window = ScriptStreamWindow(limit: 10, byteLimit: 1_000)
        _ = window.registered(handlers: 1)
        _ = window.deliver(item(1))
        _ = window.deliver(item(2))
        _ = window.deliver(item(3))

        let (dropped, action) = window.stop()
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(action, .closeInput)
        XCTAssertEqual(window.finished(item: 1), .none, "Nothing more goes out")
        XCTAssertEqual(window.deliver(item(4)).0, .refused)
        XCTAssertEqual(window.stop().0, 0)
    }

    func testEndingHandsOverWhatWaitsBeforeClosing() {
        var window = ScriptStreamWindow(limit: 10, byteLimit: 1_000)
        _ = window.deliver(item(1))
        _ = window.deliver(item(2))

        XCTAssertEqual(window.end(), .none, "The top level still runs")
        XCTAssertEqual(window.registered(handlers: 2), .write(item(1)))
        XCTAssertEqual(window.finished(item: 1), .write(item(2)))
        XCTAssertEqual(window.finished(item: 2), .closeInput)
        XCTAssertEqual(window.end(), .none, "Closed once")
    }

    func testTheHelperEndingNamesItsItemAndWhatWaited() {
        var window = ScriptStreamWindow(limit: 10, byteLimit: 1_000)
        _ = window.registered(handlers: 1)
        _ = window.deliver(item(1))
        _ = window.deliver(item(2))
        _ = window.deliver(item(3))

        let ended = window.over()
        XCTAssertEqual(ended.item, 1)
        XCTAssertEqual(ended.abandoned, 2)
        XCTAssertEqual(window.deliver(item(4)).0, .refused)
    }
}
