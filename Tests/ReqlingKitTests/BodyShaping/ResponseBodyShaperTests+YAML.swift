import Foundation
import ReqlingKit
import XCTest

/// YAML responses: classified by their content type, shown as a tree of their data or re-emitted.
extension ResponseBodyShaperTests {
    func testYAMLIsClassifiedByItsContentType() {
        XCTAssertEqual(ResponseBodyShaper.classify(Data("a: 1".utf8), contentType: "application/yaml"), .yaml)
        XCTAssertEqual(ResponseBodyShaper.classify(Data("a: 1".utf8), contentType: "application/vnd.api+yaml"), .yaml)
    }

    func testAYAMLTreeIndexesItsDataAndCopiesBackAsYAML() throws {
        let body = Data("""
        # A comment
        name: Ada
        tags: &tags [math, code]
        copy: *tags
        nested:
          on: yes
        """.utf8)

        let shaped = try ResponseBodyShaper.shape(body, as: .yaml, mode: .tree)

        guard case .tree(.json(let index)) = shaped.content else {
            return XCTFail("a tree")
        }
        XCTAssertEqual(index.sourceLanguage, .yaml)
        XCTAssertEqual(index.text(index.roots[0]), #"{"name":"Ada","tags":["math","code"],"copy":["math","code"],"nested":{"on":"yes"}}"#)
        XCTAssertEqual(YAMLFormatter.yaml(fromJSON: #"{"on":"yes","n":1}"#), "\"on\": \"yes\"\nn: 1\n")
    }

    func testAYAMLStreamIsAListOfItsDocumentsAndABrokenOneSaysWhere() throws {
        let stream = try ResponseBodyShaper.shape(Data("a: 1\n---\nb: 2\n".utf8), as: .yaml, mode: .tree)
        let broken = try ResponseBodyShaper.shape(Data("a: [1\nb: 2".utf8), as: .yaml, mode: .tree)
        let cut = try ResponseBodyShaper.shape(Data("a: [1\nb: 2".utf8), as: .yaml, mode: .tree, isTruncated: true)

        guard case .tree(.json(let index)) = stream.content, case .treeFailed(let message) = broken.content,
              case .treeFailed(let cutMessage) = cut.content else {
            return XCTFail("a tree, then failures")
        }
        XCTAssertEqual(index.text(index.roots[0]), #"[{"a":1},{"b":2}]"#)
        XCTAssertTrue(message.hasPrefix("Line "), message)
        XCTAssertEqual(cutMessage, "The body was cut short to fit the run history, so it isn't whole YAML.")
    }

    func testPrettyReEmitsYAMLAndRawLeavesItAsSent() throws {
        let body = Data("{a: 1,   b: [x, y]}  # flow style\n".utf8)

        let pretty = try ResponseBodyShaper.shape(body, as: .yaml, mode: .pretty)
        let raw = try ResponseBodyShaper.shape(body, as: .yaml, mode: .raw)

        XCTAssertEqual(text(pretty), "a: 1\nb:\n- x\n- y\n")
        XCTAssertEqual(language(pretty), .yaml)
        XCTAssertEqual(text(raw), "{a: 1,   b: [x, y]}  # flow style\n")
    }
}
