import Foundation
@testable import ReqlingKit
import XCTest

/// What an import starts from, recognized by content: Postman, OpenAPI in JSON or YAML, or neither.
final class ImportDocumentTests: XCTestCase {
    private let location = URL(fileURLWithPath: "/tmp/import/source.json")

    private func read(_ text: String) throws -> ImportDocument {
        try ImportDocument.read(Data(text.utf8), location: location)
    }

    func testRecognizesPostmanAndOpenAPIByTheirContent() throws {
        guard case .postman(let collection) = try read(#"{"info": {"name": "Shop"}, "item": []}"#) else {
            return XCTFail("a Postman collection")
        }
        XCTAssertEqual(collection.name, "Shop")
        guard case .openAPI(let yaml) = try read("openapi: 3.0.3\ninfo: {title: Zoo, version: '1'}\npaths: {}\n"),
              case .openAPI(let json) = try read(#"{"openapi": "3.1.0", "info": {"title": "Zoo"}, "paths": {}}"#),
              case .openAPI(let flow) = try read("{openapi: 3.2.0, info: {title: Flow}}") else {
            return XCTFail("OpenAPI documents")
        }
        XCTAssertEqual([yaml.title, json.title, flow.title], ["Zoo", "Zoo", "Flow"])
        XCTAssertEqual(yaml.version, "3.0.3")
    }

    func testRefusesWhatItCantImportAndSaysWhy() {
        XCTAssertThrowsError(try read(#"{"swagger": "2.0", "info": {}}"#)) { error in
            XCTAssertEqual(error as? ImportError, .swagger2("source.json"))
        }
        XCTAssertThrowsError(try read("openapi: 4.0.0\n")) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedOpenAPI("source.json", version: "4.0.0"))
        }
        XCTAssertThrowsError(try read(#"{"name": "Staging", "values": []}"#)) { error in
            XCTAssertEqual(error as? ImportError, .postman(.notACollection("source.json")))
        }
        XCTAssertThrowsError(try read("just: some yaml\n")) { error in
            XCTAssertEqual(error as? ImportError, .notImportable("source.json"))
        }
        XCTAssertThrowsError(try read(#"{"openapi": "3.1.0", "info": [1,}"#)) { error in
            guard case .syntax(let name, let detail)? = error as? ImportError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, "source.json")
            XCTAssertTrue(detail.contains("line 1"), detail)
        }
    }
}
