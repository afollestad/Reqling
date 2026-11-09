import Foundation
@testable import ReqlingKit
import XCTest

/// A project survives the trip into records and back, with secrets only in the records' `secrets`.
final class SyncRecordCoderTests: XCTestCase {
    private var token = Variable(key: "token", value: "s3cret", isSecret: true)

    private func sampleDocument() -> ProjectDocument {
        let request = RequestItem(
            name: "Create user",
            kind: .http(HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users/:id",
                queryParameters: [KeyValuePair(key: "verbose", value: "1")],
                pathVariables: [KeyValuePair(key: "id", value: "42")],
                headers: [KeyValuePair(key: "X-Trace", value: "on", isEnabled: false)],
                auth: .bearer(token: "{{token}}")
            )),
            scripts: ScriptSet(preRequest: "sign();", postResponse: "check();"),
            runsInheritedScripts: false
        )
        let grpc = RequestItem(name: "Echo", kind: .grpc(GRPCRequestSpec(target: "localhost:50051", service: "Echo", method: "Unary")))
        let socket = RequestItem(name: "Live", kind: .webSocket(WebSocketRequestSpec(url: "wss://live", subprotocols: ["chat"])))
        let inner = RequestFolder(name: "Admin", auth: .basic(username: "root", password: "{{password}}"), children: [.request(grpc)])
        let users = RequestFolder(
            name: "Users",
            scripts: ScriptSet(preRequest: "folder();"),
            runsInheritedScripts: false,
            children: [.request(request), .folder(inner)]
        )
        return ProjectDocument(
            name: "API",
            auth: .apiKey(name: "X-Key", value: "{{key}}", location: .header),
            scripts: ScriptSet(stream: "project();"),
            defaultEnvironment: RequestEnvironment(
                name: RequestEnvironment.defaultName,
                variables: [Variable(key: "baseUrl", value: "https://api"), token]
            ),
            environments: [RequestEnvironment(name: "Staging"), RequestEnvironment(name: "Production")],
            items: [.folder(users), .request(socket)]
        )
    }

    private func keychain(for document: ProjectDocument) -> [String: String] {
        [SecretKey.variable(token.id, in: document.defaultEnvironment.id): "s3cret"]
    }

    func testAProjectRoundTripsThroughItsRecords() throws {
        let document = sampleDocument()

        let records = try ProjectRecordCoder.records(for: document, secrets: keychain(for: document))
        let decoded = try ProjectRecordCoder.document(document.id, from: Array(records.values), local: nil)

        XCTAssertEqual(decoded.document, document)
        XCTAssertEqual(decoded.secrets, keychain(for: document))
        XCTAssertEqual(records.count, 1 + 5 + 3, "The project, each folder and request, and each environment")
    }

    func testPayloadsCarryNoSecretValues() throws {
        let document = sampleDocument()

        let records = try ProjectRecordCoder.records(for: document, secrets: keychain(for: document))

        for record in records.values {
            XCTAssertFalse(record.payload.prettyPrinted().contains("s3cret"), record.id.description)
        }
        let environment = try XCTUnwrap(records[SyncRecordID(zone: .project(document.id), name: document.defaultEnvironment.id.description)])
        XCTAssertEqual(environment.secrets, [token.id.description: "s3cret"])
    }

    /// A Mac that couldn't read its Keychain, or never received a value, sends none; the receiver keeps its own.
    func testAnAbsentSecretIsNeverSentOrAppliedAsBlank() throws {
        var document = sampleDocument()

        let unread = try ProjectRecordCoder.records(for: document, secrets: nil)
        let missing = try ProjectRecordCoder.records(for: document, secrets: [:])
        let environmentID = SyncRecordID(zone: .project(document.id), name: document.defaultEnvironment.id.description)
        let decoded = try ProjectRecordCoder.document(document.id, from: Array(missing.values), local: document)

        XCTAssertNil(unread[environmentID]?.secrets)
        XCTAssertEqual(missing[environmentID]?.secrets, [:])
        XCTAssertEqual(decoded.document.defaultEnvironment.variables.last?.value, "s3cret", "The receiver keeps its own value")
        XCTAssertEqual(decoded.secrets, [:], "Nothing is stored over it")
        document.defaultEnvironment.variables[1].value = ""
        XCTAssertEqual(try ProjectRecordCoder.document(document.id, from: Array(missing.values), local: nil).document, document)
    }

    func testAZoneWithoutItsProjectOrDefaultEnvironmentIsRefused() throws {
        let document = sampleDocument()
        let records = try ProjectRecordCoder.records(for: document, secrets: [:])

        XCTAssertThrowsError(try ProjectRecordCoder.document(document.id, from: records.values.filter { $0.type != .project }, local: nil))
        XCTAssertThrowsError(try ProjectRecordCoder.document(
            document.id,
            from: records.values.filter { $0.id.name != document.defaultEnvironment.id.description },
            local: nil
        ))
    }

    /// The keys a payload can hold are the schema an older Mac may not understand: change them, and bump
    /// `ProjectRecordCoder.schemaVersion` with this list, so an older Mac defers those records rather than strip them.
    func testThePayloadSchemaMatchesItsVersion() throws {
        let document = sampleDocument()
        var keys: [SyncRecordType: Set<String>] = [:]
        func collect(_ json: OrderedJSON, into set: inout Set<String>, path: String) {
            switch json {
            case .object(let members):
                for member in members {
                    set.insert(path + member.key)
                    collect(member.value, into: &set, path: path + member.key + ".")
                }
            case .array(let items):
                for item in items {
                    collect(item, into: &set, path: path + "[].")
                }
            case .null, .bool, .number, .string:
                break
            }
        }
        for record in try ProjectRecordCoder.records(for: document, secrets: [:]).values {
            collect(record.payload, into: &keys[record.type, default: []], path: "")
        }

        XCTAssertEqual(ProjectRecordCoder.schemaVersion, 1)
        XCTAssertEqual(keys[.project]?.filter { !$0.contains(".") }.sorted(), [
            "auth", "defaultEnvironmentID", "environmentOrder", "grpc", "itemOrder", "name", "scripts", "tls"
        ])
        XCTAssertEqual(keys[.folder]?.filter { !$0.contains(".") }.sorted(), [
            "auth", "id", "inheritScripts", "name", "order", "parentID", "scripts"
        ])
        XCTAssertEqual(keys[.request]?.filter { !$0.contains(".") }.sorted(), [
            "grpc", "http", "id", "inheritScripts", "kind", "name", "parentID", "scripts", "websocket"
        ])
        XCTAssertEqual(keys[.environment]?.filter { !$0.contains(".") }.sorted(), ["id", "name", "variables"])
    }

    func testCurrentValuesKeepTheirSecretsOutOfThePayload() throws {
        let scope = CurrentValueScope.environment(ProjectID(), EnvironmentID())
        let record = try LibraryRecordCoder.currentValuesRecord(
            scope,
            values: ["token": .secret, "page": .plain("2"), "hidden": .unset],
            secrets: [SecretKey.currentValue("token", in: scope.environmentID): "s3cret"]
        )

        let decoded = try LibraryRecordCoder.currentValues(from: record)

        XCTAssertFalse(record.payload.prettyPrinted().contains("s3cret"))
        XCTAssertEqual(decoded.values, ["token": .secret, "page": .plain("2"), "hidden": .unset])
        XCTAssertEqual(decoded.secrets, ["token": "s3cret"])
        XCTAssertEqual(LibraryRecordCoder.scope(of: record.id), scope)
    }

    func testZoneAndRecordNamesParseStrictly() {
        let project = ProjectID()

        XCTAssertEqual(SyncZone(name: "project-\(project)"), .project(project))
        XCTAssertEqual(SyncZone(name: "library"), .library)
        XCTAssertNil(SyncZone(name: "project-\(project.description.uppercased())x"))
        XCTAssertNil(SyncZone(name: "project-../../etc"))
        XCTAssertNil(SyncZone(name: "other"))
        XCTAssertEqual(LibraryRecordCoder.tombstonedProject(LibraryRecordCoder.tombstoneRecordID(project)), project)
        XCTAssertNil(LibraryRecordCoder.scope(of: SyncRecordID(zone: .project(project), name: "current-nope")))
    }
}
