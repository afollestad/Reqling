import Foundation
@testable import ReqlingKit
import XCTest

final class BodyTreeTests: XCTestCase {
    private func json(_ text: String, sequence: Bool = false) throws -> JSONStructureIndex {
        try JSONStructureIndex.build(Data(text.utf8), allowsSequence: sequence)
    }

    func testListsAContainersValuesOneLevelAtATime() throws {
        let index = try json(#"{"a": 1, "b\"q": {"c": [true, null, "xé"]}, "d": -2.5e3, "e": []}"#)
        let root = try XCTUnwrap(index.rootEntries().first)
        XCTAssertEqual(root.kind, .object)
        XCTAssertEqual(root.childCount, 4)

        let members = index.children(of: try XCTUnwrap(root.container))
        XCTAssertEqual(members.map(\.key), ["a", "b\"q", "d", "e"])
        XCTAssertEqual(members.map(\.kind), [.number, .object, .number, .array])
        XCTAssertEqual(index.text(members[2].valueRange), "-2.5e3", "numbers keep their literal text")

        let nested = index.children(of: try XCTUnwrap(index.children(of: try XCTUnwrap(members[1].container)).first?.container))
        XCTAssertEqual(nested.map(\.kind), [.bool, .null, .string])
        XCTAssertEqual(index.string(nested[2].valueRange), "xé")
        XCTAssertEqual(index.children(of: try XCTUnwrap(members[3].container)), [])
    }

    func testNewlineDelimitedJSONHasOneRootPerLine() throws {
        let index = try json("{\"a\":1}\n[2]\n\"three\"\n", sequence: true)
        XCTAssertEqual(index.rootEntries().map(\.kind), [.object, .array, .string])
        XCTAssertEqual(index.children(of: try XCTUnwrap(index.rootEntries()[1].container)).count, 1)
    }

    func testDecodesEscapesAndSurrogatePairs() throws {
        let index = try json(#"["tab\tquote\"slash\/ 😀 lone \ud800 end"]"#)
        let item = try XCTUnwrap(index.children(of: 0).first)
        XCTAssertEqual(index.string(item.valueRange), "tab\tquote\"slash/ 😀 lone \u{FFFD} end")
        XCTAssertEqual(index.string(item.valueRange, limit: 6), "tab\t", "a cut keeps whole characters")
    }

    func testBuildsJSONAndXMLPaths() {
        let json: [BodyTreePathComponent] = [.key("users"), .index(0), .key("first name"), .key("a\"b")]
        XCTAssertEqual(BodyTreePathComponent.jsonPath(json), #"$.users[0]["first name"]["a\"b"]"#)
        let xml: [BodyTreePathComponent] = [
            .xml(name: "stations", position: nil, isAttribute: false),
            .xml(name: "station", position: 3, isAttribute: false),
            .xml(name: "id", position: nil, isAttribute: true)
        ]
        XCTAssertEqual(BodyTreePathComponent.xmlPath(xml), "/stations/station[3]/@id")
    }

    func testFindsKeysAndValuesWithTheirPaths() throws {
        let index = try json(#"{"name": "Ada", "tags": ["x", "NAMED"], "nested": {"label": "café name"}}"#)
        let result = try BodyStructure.json(index).find("name")
        XCTAssertEqual(result.matches.map(\.path), [[0, 0], [0, 1, 1], [0, 2, 0]])
        XCTAssertEqual(try BodyStructure.json(index).find("CAFÉ").matches.map(\.path), [[0, 2, 0]], "escaped text matches decoded")
        let limited = try BodyStructure.json(index).find("x", limit: 1)
        XCTAssertEqual(limited, BodyTreeSearchResult(matches: [BodyTreeMatch(path: [0, 1, 0])], isTruncated: true))
    }

    func testIndexesXMLElementsAttributesTextAndComments() throws {
        let xml = """
        <?xml version="1.0"?>
        <!-- fixture -->
        <stations count="2">
          <station id="1" fuel="ELEC"><name>Café</name><notes><![CDATA[<raw> & text]]></notes></station>
          <station id="2"/>
        </stations>
        """
        let index = try XMLStructureIndex.build(Data(xml.utf8))
        XCTAssertEqual(index.roots.map { index.nodes[$0].kind }, [.comment, .element])
        let root = index.roots[1]
        let rootChildren = index.children(of: root)
        XCTAssertEqual(rootChildren.map { index.nodes[$0].name }, ["count", "station", "station"])
        let first = index.children(of: rootChildren[1])
        XCTAssertEqual(first.map { index.nodes[$0].kind }, [.attribute, .attribute, .element, .element])
        XCTAssertEqual(first.prefix(2).map { index.nodes[$0].name }, ["fuel", "id"], "attributes by name")
        let name = index.children(of: first[2])
        XCTAssertEqual(name.map { index.nodes[$0].value }, ["Café"])
        XCTAssertEqual(index.children(of: first[3]).map { index.nodes[$0].kind }, [.cdata])
        XCTAssertEqual(index.position(of: rootChildren[2]), 2)
        XCTAssertEqual(try BodyStructure.xml(index).find("café").matches.map(\.path), [[1, 1, 2, 0]])
    }

    func testReportsWhereXMLStopsBeingWellFormedAndNeverLoadsExternalEntities() {
        XCTAssertThrowsError(try XMLStructureIndex.build(Data("<a><b></a>".utf8))) { error in
            guard case .syntax(_, let line, _) = error as? XMLIndexError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(line, 1)
        }
        let external = """
        <?xml version="1.0"?>
        <!DOCTYPE a [<!ENTITY secret SYSTEM "file:///etc/hosts">]>
        <a>&secret;</a>
        """
        let index = try? XMLStructureIndex.build(Data(external.utf8))
        XCTAssertFalse(index?.nodes.contains { $0.value.contains("localhost") } ?? false)
    }

    func testTreeModeShapesJSONAndXMLAndExplainsFailures() throws {
        let tree = try ResponseBodyShaper.shape(Data(#"{"a":1}"#.utf8), as: .json(.declared), mode: .tree)
        guard case .tree(.json(let index)) = tree.content else {
            return XCTFail("\(tree.content)")
        }
        XCTAssertEqual(index.containerCount, 1)

        let broken = try ResponseBodyShaper.shape(Data("{\"a\": }".utf8), as: .json(.declared), mode: .tree)
        guard case .treeFailed(let message) = broken.content else {
            return XCTFail("\(broken.content)")
        }
        XCTAssertEqual(message, "Line 1, column 7: Expected a JSON value.")
        XCTAssertEqual(broken.format, .json(.declared), "Tree stays offered")

        let xml = try ResponseBodyShaper.shape(Data("<a/>".utf8), as: .xml, mode: .tree)
        guard case .tree(.xml) = xml.content else {
            return XCTFail("\(xml.content)")
        }
    }

    func testATimelineSearchesEveryMessageWithPathsFromItsRow() throws {
        let messages = [#"{"text": "hi"}"#, "{\"text\": \"cut", #"{"other": {"text": "HI there"}}"#].enumerated().map { sequence, json in
            MessageTimeline.Message(
                event: GRPCMessageEvent(direction: .received, offset: 0, json: json, byteCount: 1, sequence: sequence),
                index: try? JSONStructureIndex.build(Data(json.utf8))
            )
        }
        let timeline = MessageTimeline(id: UUID(), messages: messages)
        XCTAssertNil(messages[1].index, "a message cut short doesn't parse")
        XCTAssertEqual(messages[2].fields.map(\.key), ["other"])
        XCTAssertEqual(try BodyStructure.messages(timeline).find("hi").matches.map(\.path), [[0, 0], [2, 0, 0]])
    }

    /// An event's row matches its type and ID, and data or a note that isn't JSON matches as text.
    func testATimelineRowMatchesWhatItsTreeDoesNotIndex() throws {
        let entries = [
            EventStreamEntry(sequence: 0, offset: 0, kind: .event(ServerSentEvent(type: "update", id: "abc", data: #"{"n": 1}"#))),
            EventStreamEntry(sequence: 1, offset: 0, kind: .event(ServerSentEvent(data: "plain update"))),
            EventStreamEntry(sequence: 2, offset: 0, kind: .note("Reconnected"))
        ]
        let messages = entries.map { entry in
            let item = TimelineItem(entry)
            return MessageTimeline.Message(item: item, index: item.isJSON ? try? JSONStructureIndex.build(Data(item.text.utf8)) : nil)
        }
        let structure = BodyStructure.messages(MessageTimeline(id: UUID(), messages: messages))

        XCTAssertEqual(try structure.find("update").matches.map(\.path), [[0], [1]])
        XCTAssertEqual(try structure.find("ABC").matches.map(\.path), [[0]])
        XCTAssertEqual(try structure.find("reconnect").matches.map(\.path), [[2]])
    }

    /// A body cut to fit the response cache keeps everything before the cut; without being told, it is an error.
    func testACutBodyClosesAtItsLastCompleteValue() throws {
        let cut = #"{"a": [1, 2, {"b": "xy"#
        XCTAssertThrowsError(try json(cut)) { error in
            XCTAssertEqual(error as? JSONIndexError, .syntax(message: "A string is never closed.", line: 1, column: 20))
        }
        let index = try JSONStructureIndex.build(Data(cut.utf8), allowsTruncation: true)
        let root = try XCTUnwrap(index.rootEntries().first)
        XCTAssertTrue(root.isTruncated)
        let members = index.children(of: try XCTUnwrap(root.container))
        XCTAssertEqual(members.map(\.key), ["a"])
        let items = index.children(of: try XCTUnwrap(members[0].container))
        XCTAssertEqual(items.map(\.kind), [.number, .number, .object])
        XCTAssertEqual(items.map(\.isTruncated), [false, false, true])
        XCTAssertEqual(index.children(of: try XCTUnwrap(items[2].container)), [], "a value cut short is dropped")

        let betweenValues = try JSONStructureIndex.build(Data(#"[{"id":1},{"id":2},{"i"#.utf8), allowsTruncation: true)
        XCTAssertEqual(betweenValues.children(of: 0).map(\.childCount), [1, 1, 0])
        let numberAtCut = try JSONStructureIndex.build(Data("[1, 2, 12".utf8), allowsTruncation: true)
        XCTAssertEqual(numberAtCut.children(of: 0).map { numberAtCut.text($0.valueRange) }, ["1", "2"], "12 may be 1234 cut short")
        XCTAssertThrowsError(try JSONStructureIndex.build(Data("tru".utf8), allowsTruncation: true), "nothing complete to keep")
        XCTAssertThrowsError(try JSONStructureIndex.build(Data("[1, }".utf8), allowsTruncation: true), "a real syntax error still fails")
    }

    func testTreeModeKeepsWhatCameBeforeACut() throws {
        let cut = Data(#"{"stations": [{"id": 1}, {"id": 2}, {"na"#.utf8)
        let shaped = try ResponseBodyShaper.shape(cut, as: .json(.declared), mode: .tree, isTruncated: true)
        guard case .tree(.json(let index)) = shaped.content else {
            return XCTFail("\(shaped.content)")
        }
        XCTAssertEqual(index.rootEntries().first?.isTruncated, true)

        let xml = try XMLStructureIndex.build(Data("<a><b>one</b><b>tw".utf8), allowsTruncation: true)
        XCTAssertEqual(xml.children(of: xml.roots[0]).map { xml.nodes[$0].name }, ["b", "b"])
        XCTAssertThrowsError(try XMLStructureIndex.build(Data("<a><b>one</b><b>tw".utf8)))
    }
}
