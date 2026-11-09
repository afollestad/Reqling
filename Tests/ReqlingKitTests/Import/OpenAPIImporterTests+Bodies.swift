import Foundation
@testable import ReqlingKit
import XCTest

/// Parameters as rows and example bodies, from examples or made from schemas.
extension OpenAPIImporterTests {
    func testParametersBecomeRowsOnWhenRequired() async throws {
        let list = try spec(try await petstore(), "pets", "List pets")

        XCTAssertEqual(list.queryParameters.map { "\($0.key)=\($0.value) \($0.isEnabled)" }, ["limit=20 false", "tags=dog false", "tags=🐱 false"])
        XCTAssertEqual(list.headers.map { "\($0.key)=\($0.value) \($0.isEnabled)" }, ["X-Trace=3fa85f64-5717-4562-b3fc-2c963f66afa6 true"],
                       "Accept is left to the response")
    }

    func testAPathVariableTakesOnlyAValueTheDocumentGives() async throws {
        let plan = try await plan("""
        openapi: 3.1.0
        info: {title: Paths, version: '1'}
        paths:
          /orgs/{org}/teams/{team}:
            get:
              summary: Team
              parameters:
                - {name: org, in: path, required: true, schema: {type: string}}
                - {name: team, in: path, required: true, schema: {type: string, default: core}}
              responses: {}
        """)

        let values = try spec(plan, "Team").pathVariables.map { "\($0.key)=\($0.value)" }

        XCTAssertEqual(values, ["org=", "team=core"], "Left empty, Send asks for it rather than sending a made-up “string”")
    }

    func testAJSONBodyIsMadeFromItsSchemaAcrossFiles() async throws {
        let plan = try await petstore()
        let add = try spec(plan, "pets", "Add a pet")

        XCTAssertEqual(add.body.mode, .raw)
        XCTAssertEqual(add.body.raw.contentType, "application/json", "JSON over XML")
        XCTAssertEqual(add.body.raw.text, """
        {
          "name": "Rex",
          "status": "available",
          "emoji": "🐶",
          "category": {
            "name": "string"
          },
          "owner": {
            "name": "Ada",
            "pets": []
          }
        }
        """, "readOnly id left out; the recursive category and the pets loop stop")
        let order = try spec(plan, "store", "Place an order")
        XCTAssertEqual(order.body.mode, .urlEncoded)
        XCTAssertEqual(order.body.urlEncoded.map { "\($0.key)=\($0.value) \($0.isEnabled)" }, ["petId=0 true", "note=string false"])
    }

    func testOtherMediaTypesAndExamples() async throws {
        let plan = try await plan(Self.mediaDocument)
        let upload = try spec(plan, "Upload")
        let raw = try spec(plan, "Raw")

        let parts = upload.body.formData.map { "\($0.key) \($0.kind) \($0.value) \($0.contentType ?? "-")" }
        XCTAssertEqual(parts, ["title text Cat -", "photo file  image/png"])
        XCTAssertEqual(raw.body.mode, .binary)
        XCTAssertEqual(raw.body.binary.contentType, "application/octet-stream")
        XCTAssertEqual(try spec(plan, "Config").body.raw.text, "name: app\nenabled: true\ntags:\n- a\n- b\n")
        XCTAssertEqual(try spec(plan, "Choice").body.raw.text, "{\n  \"kind\": \"dog\",\n  \"barks\": true\n}")
        XCTAssertEqual(messages(plan, .node(["Upload"])), ["Choose the file for “photo”."])
        XCTAssertEqual(messages(plan, .node(["Raw"])), ["Choose its body's file (application/octet-stream)."])
    }

    private static let mediaDocument = """
    openapi: 3.1.0
    info: {title: Media, version: '1'}
    paths:
      /upload:
        post:
          summary: Upload
          requestBody:
            content:
              multipart/form-data:
                schema:
                  type: object
                  properties:
                    title: {type: string, example: Cat}
                    photo: {type: string, format: binary}
                encoding:
                  photo: {contentType: image/png}
          responses: {}
      /raw:
        put:
          summary: Raw
          requestBody:
            content:
              application/octet-stream: {}
          responses: {}
      /config:
        post:
          summary: Config
          requestBody:
            content:
              application/yaml:
                examples:
                  first: {value: {name: app, enabled: true, tags: [a, b]}}
          responses: {}
      /choice:
        post:
          summary: Choice
          requestBody:
            content:
              application/json:
                schema:
                  oneOf: [{$ref: '#/components/schemas/Dog'}, {$ref: '#/components/schemas/Cat'}]
                  discriminator: {propertyName: kind, mapping: {dog: '#/components/schemas/Dog'}}
          responses: {}
    components:
      schemas:
        Dog: {type: object, properties: {kind: {type: string}, barks: {type: boolean}}}
        Cat: {type: object, properties: {kind: {type: string}}}
    """
}
