import Foundation
import ReqlingKit
import XCTest

final class ResponseBodyShaperTests: XCTestCase {
    func testClassifiesFromTheContentTypeAndFirstBytesAlone() {
        let json = Data(#"{"a":1}"#.utf8)
        XCTAssertEqual(ResponseBodyShaper.classify(Data(), contentType: "application/json"), .empty)
        XCTAssertEqual(ResponseBodyShaper.classify(json, contentType: "application/problem+json; charset=utf-8"), .json(.declared))
        XCTAssertEqual(ResponseBodyShaper.classify(json, contentType: "application/x-ndjson"), .json(.lines))
        XCTAssertEqual(ResponseBodyShaper.classify(json, contentType: "text/plain"), .json(.sniffed))
        XCTAssertEqual(ResponseBodyShaper.classify(Data([0xEF, 0xBB, 0xBF] + Array(" \n[1]".utf8)), contentType: nil), .json(.sniffed))
        XCTAssertEqual(ResponseBodyShaper.classify(Data("hello {".utf8), contentType: "text/plain"), .text(.plainText))
        XCTAssertEqual(ResponseBodyShaper.classify(Data("<a/>".utf8), contentType: "application/atom+xml"), .xml)
        XCTAssertEqual(ResponseBodyShaper.classify(Data("<p>".utf8), contentType: "text/html"), .text(.html))
        XCTAssertEqual(ResponseBodyShaper.classify(Data([0x89, 0x50]), contentType: "image/png"), .image)
    }

    func testPrettyPrintsJSONAndLeavesRawAsSent() throws {
        let body = Data(#"{"a":[1]}"#.utf8)

        let pretty = try ResponseBodyShaper.shape(body, as: .json(.declared), mode: .pretty)
        let raw = try ResponseBodyShaper.shape(body, as: .json(.declared), mode: .raw)

        XCTAssertEqual(text(pretty), "{\n  \"a\": [\n    1\n  ]\n}")
        XCTAssertEqual(text(raw), #"{"a":[1]}"#)
        XCTAssertEqual(language(pretty), .json)
        XCTAssertEqual(pretty.format, .json(.declared))
    }

    func testConfirmsSniffedJSONAndFallsBackToPlainTextWhenItDoesNotParse() throws {
        let valid = try ResponseBodyShaper.shape(Data("[1, 2]".utf8), as: .json(.sniffed), mode: .pretty)
        XCTAssertEqual(valid.format, .json(.declared))
        XCTAssertEqual(text(valid), "[\n  1,\n  2\n]")

        let invalid = try ResponseBodyShaper.shape(Data("{not json}".utf8), as: .json(.sniffed), mode: .pretty)
        XCTAssertEqual(invalid.format, .text(.plainText))
        XCTAssertEqual(text(invalid), "{not json}")
        XCTAssertEqual(language(invalid), .plainText)
    }

    func testPrettyPrintsEachLineOfNewlineDelimitedJSON() throws {
        let shaped = try ResponseBodyShaper.shape(Data("{\"a\":1}\n{\"b\":2}\n".utf8), as: .json(.lines), mode: .pretty)
        XCTAssertEqual(text(shaped), "{\n  \"a\": 1\n}\n{\n  \"b\": 2\n}")
    }

    func testReportsBinaryBodiesAndShowsOtherTextAsSent() throws {
        let binary = try ResponseBodyShaper.shape(Data([0xFF, 0xFE, 0x00]), as: .text(.plainText), mode: .raw)
        guard case .binary(let byteCount) = binary.content else {
            return XCTFail("\(binary.content)")
        }
        XCTAssertEqual(byteCount, 3)

        let xml = try ResponseBodyShaper.shape(Data("<a/>".utf8), as: .xml, mode: .pretty)
        XCTAssertEqual(text(xml), "<a/>")
        XCTAssertEqual(language(xml), .xml)

        let undecodableImage = try ResponseBodyShaper.shape(Data("not a png".utf8), as: .image, mode: .raw)
        XCTAssertEqual(undecodableImage.format, .text(.plainText))
    }

    private func text(_ shaped: ShapedBody) -> String? {
        if case .text(let document) = shaped.content {
            return document.text(in: 0..<document.length)
        }
        return nil
    }

    private func language(_ shaped: ShapedBody) -> SyntaxLanguage? {
        if case .text(let document) = shaped.content {
            return document.language
        }
        return nil
    }
}
