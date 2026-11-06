import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// Drives the tree's coordinator and outline directly, as the representable wires them.
@MainActor
final class BodyTreeViewTests: XCTestCase {
    private var coordinator: BodyTreeCoordinator!
    private var outline: BodyTreeOutlineView!

    override func setUp() async throws {
        coordinator = BodyTreeCoordinator()
        outline = BodyTreeView.makeOutline(coordinator: coordinator)
        outline.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    }

    override func tearDown() async throws {
        coordinator = nil
        outline = nil
    }

    private func showJSON(_ text: String) throws {
        coordinator.show(.json(try JSONStructureIndex.build(Data(text.utf8))))
    }

    private func items() -> [BodyTreeItem] {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? BodyTreeItem }
    }

    private func label(_ item: BodyTreeItem) -> String {
        coordinator.rowText(for: item).text.string
    }

    func testOpensTheTopLevelAndBucketsLargeContainers() throws {
        try showJSON("[" + (0..<250).map(String.init).joined(separator: ",") + "]")
        XCTAssertEqual(items().map(label), ["[ 250 items ]", "[0 … 99]", "[100 … 199]", "[200 … 249]"])

        try showJSON("[" + (0..<15_000).map(String.init).joined(separator: ",") + "]")
        let buckets = Array(items().dropFirst())
        XCTAssertEqual(buckets.map(\.range), [0..<10_000, 10_000..<15_000])
        XCTAssertEqual(coordinator.displayChildren(of: buckets[0]).count, 100, "nested buckets of 100")
    }

    func testRowsShowKeysAndValuesAsTheyRead() throws {
        try showJSON(#"{"name": "Ada\nLovelace", "n": 1.50, "ok": true, "tags": [], "nested": {"a": null}}"#)
        XCTAssertEqual(items().dropFirst().map(label), [
            #""name": "Ada↵Lovelace""#,
            #""n": 1.50"#,
            #""ok": true"#,
            #""tags": []"#,
            #""nested": { 1 key }"#
        ])
        XCTAssertEqual(coordinator.rowText(for: items()[1]).accessibilityLabel, "name, string, Ada↵Lovelace")
    }

    /// A real double-click sets the row it landed on, which a test cannot; `toggle(row:)` is what it then runs.
    func testDoubleClickingAContainerTogglesIt() throws {
        try showJSON(#"{"data": {"user": {"name": "Ada"}}, "ok": true}"#)
        XCTAssertEqual(outline.doubleAction, #selector(BodyTreeCoordinator.toggleClickedRow(_:)))
        XCTAssertTrue(outline.target === coordinator)
        let data = try XCTUnwrap(items().first { label($0) == #""data": { 1 key }"# })
        let flag = try XCTUnwrap(items().first { label($0) == #""ok": true"# })

        coordinator.toggle(row: outline.row(forItem: data))
        XCTAssertTrue(outline.isItemExpanded(data))
        XCTAssertEqual(items().count, 4, "only one level opens")
        coordinator.toggle(row: outline.row(forItem: data))
        XCTAssertFalse(outline.isItemExpanded(data))
        coordinator.toggle(row: outline.row(forItem: flag))
        coordinator.toggle(row: -1)
        XCTAssertEqual(items().count, 3, "a value, and no row, change nothing")
    }

    func testCopiesValuesKeysAndPaths() throws {
        try showJSON(#"{"users": [{"id": 1, "first name": "Ada"}]}"#)
        coordinator.expand(from: nil, budget: BodyTreeView.expandBudget)
        let name = try XCTUnwrap(items().first { label($0) == #""first name": "Ada""# })
        XCTAssertEqual(coordinator.path(of: name), #"$.users[0]["first name"]"#)
        XCTAssertEqual(coordinator.key(of: name), "first name")
        XCTAssertEqual(coordinator.value(of: name), "Ada")
        let user = try XCTUnwrap(name.parentNode)
        XCTAssertEqual(coordinator.value(of: user), "{\n  \"id\": 1,\n  \"first name\": \"Ada\"\n}")
    }

    func testExpandAllStopsAtItsBudget() throws {
        let items = (0..<3_000).map { #"{"id": \#($0), "tags": ["a", "b"]}"# }.joined(separator: ",")
        try showJSON("[" + items + "]")

        coordinator.expand(from: nil, budget: 500)

        XCTAssertLessThan(outline.numberOfRows, 500 + BodyTreeItem.bucketSize + 10)
        XCTAssertGreaterThan(outline.numberOfRows, 400)
    }

    func testRevealsASearchMatchInsideBuckets() throws {
        let items = (0..<1_000).map { $0 == 777 ? #"{"needle": true}"# : #"{"hay": \#($0)}"# }.joined(separator: ",")
        let structure = BodyStructure.json(try JSONStructureIndex.build(Data(("[" + items + "]").utf8)))
        coordinator.show(structure)
        let match = try XCTUnwrap(try structure.find("needle").matches.first)
        XCTAssertEqual(match.path, [0, 777, 0])

        coordinator.reveal(match)

        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? BodyTreeItem)
        XCTAssertEqual(label(selected), #""needle": true"#)
        XCTAssertEqual(coordinator.path(of: selected), "$[777].needle")
    }

    func testXMLRowsAndPaths() throws {
        let xml = #"<stations><station id="1"><name>Café</name></station><station id="2"/></stations>"#
        coordinator.show(.xml(try XMLStructureIndex.build(Data(xml.utf8))))
        coordinator.expand(from: nil, budget: BodyTreeView.expandBudget)
        XCTAssertEqual(items().map(label), ["<stations>", "<station>", #"@id = "1""#, "<name> Café", "Café", "<station>", #"@id = "2""#])
        let secondID = try XCTUnwrap(items().last)
        XCTAssertEqual(coordinator.path(of: secondID), "/stations/station[2]/@id")
        let stations = try XCTUnwrap(items().first)
        XCTAssertEqual(coordinator.value(of: stations), #"<stations><station id="1"><name>Café</name></station><station id="2"/></stations>"#)
    }

    /// Newline-delimited JSON's values bucket at the top level like any large container, and start closed.
    func testNewlineDelimitedValuesBucketAtTheTopLevel() throws {
        let lines = (0..<1_000).map { #"{"a": \#($0)}"# }.joined(separator: "\n")
        coordinator.show(.json(try JSONStructureIndex.build(Data(lines.utf8), allowsSequence: true)))
        XCTAssertEqual(items().map(label).prefix(2), ["[0 … 99]", "[100 … 199]"])
        XCTAssertEqual(outline.numberOfRows, 10)

        coordinator.reveal(BodyTreeMatch(path: [3, 0]))
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? BodyTreeItem)
        XCTAssertEqual(label(selected), #""a": 3"#)
        XCTAssertEqual(coordinator.path(of: selected), "$[3].a")
        XCTAssertEqual(label(try XCTUnwrap(selected.parentNode)), "3: { 1 key }")
    }

    /// A long timeline opens only its newest messages, within the open budget, so showing its tree stays quick; a
    /// message that arrives later still opens as it lands.
    func testALongTimelineOpensOnlyItsNewestMessages() throws {
        let fields = 20
        let json = "{" + (0..<fields).map { #""k\#($0)": \#($0)"# }.joined(separator: ",") + "}"
        func message(_ sequence: Int) throws -> MessageTimeline.Message {
            MessageTimeline.Message(
                item: TimelineItem(sequence: sequence, offset: 0, byteCount: 1, text: json, header: .event(type: "message", id: nil)),
                index: try JSONStructureIndex.build(Data(json.utf8))
            )
        }
        let id = UUID()
        let messages = try (0..<300).map(message)

        coordinator.show(.messages(MessageTimeline(id: id, messages: messages)))

        let opened = coordinator.roots.filter { outline.isItemExpanded($0) }.map(\.range.lowerBound)
        let fitting = BodyTreeView.openBudget / fields
        XCTAssertEqual(opened, Array((300 - fitting)..<300), "the newest that fit")
        XCTAssertEqual(outline.numberOfRows, 300 + fitting * fields)

        coordinator.show(.messages(MessageTimeline(id: id, messages: messages + [try message(300)])))
        XCTAssertTrue(outline.isItemExpanded(try XCTUnwrap(coordinator.roots.last)))
    }

    /// A streaming call updates its tree in place: new messages append, trimmed ones go, and what was expanded stays.
    func testATimelineUpdatesInPlaceKeepingExpansion() throws {
        func timeline(_ sequences: Range<Int>, id: UUID) throws -> BodyStructure {
            .messages(MessageTimeline(id: id, messages: try sequences.map { sequence in
                let json = #"{"index": \#(sequence), "nested": {"a": 1}}"#
                return MessageTimeline.Message(
                    event: GRPCMessageEvent(
                        direction: sequence.isMultiple(of: 2) ? .sent : .received,
                        offset: 0,
                        json: json,
                        byteCount: 2,
                        sequence: sequence
                    ),
                    index: try JSONStructureIndex.build(Data(json.utf8))
                )
            }))
        }
        let id = UUID()
        coordinator.show(try timeline(0..<2, id: id))
        let messages = items().filter { $0.parentNode === coordinator.document }
        XCTAssertEqual(messages.map(label).map { String($0.prefix(6)) }, ["↑ Sent", "↓ Rece"])
        XCTAssertEqual(outline.numberOfRows, 6, "messages open on their fields")
        let first = try XCTUnwrap(messages.first)
        let nested = try XCTUnwrap(coordinator.displayChildren(of: first).last)
        outline.expandOne(nested)
        outline.collapseItem(messages[1])
        XCTAssertEqual(outline.numberOfRows, 5)

        coordinator.show(try timeline(0..<3, id: id))
        XCTAssertTrue(outline.isItemExpanded(nested), "expansion survives an update")
        XCTAssertFalse(outline.isItemExpanded(messages[1]), "so does collapsing")
        XCTAssertEqual(outline.numberOfRows, 8, "a new message arrives open")

        coordinator.show(try timeline(1..<4, id: id))
        XCTAssertFalse(items().contains { $0 === first }, "a trimmed message goes")
        XCTAssertEqual(items().filter { $0.parentNode === coordinator.document }.map(\.range.lowerBound), [0, 1, 2])

        coordinator.reveal(BodyTreeMatch(path: [2, 1, 0]))
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? BodyTreeItem)
        XCTAssertEqual(label(selected), #""a": 1"#)
        XCTAssertEqual(coordinator.path(of: selected), "$.nested.a", "paths start inside each message")
    }

    func testACutContainerSaysItsCountIsPartial() throws {
        coordinator.show(.json(try JSONStructureIndex.build(Data(#"{"stations": [{"id": 1}, {"id": 2}, {"na"#.utf8), allowsTruncation: true)))
        coordinator.expand(from: nil, budget: BodyTreeView.expandBudget)
        XCTAssertEqual(items().prefix(2).map(label), ["{ 1 key… }", #""stations": [ 3 items… ]"#])
        XCTAssertEqual(coordinator.rowText(for: items()[1]).accessibilityLabel, "stations, array, 3 items…, cut short")
    }
}
