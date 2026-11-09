import CryptoKit
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

    /// `sampleDocument` with the optional parts filled too, so the schema test sees each key a payload can hold.
    private func richDocument() -> ProjectDocument {
        var document = sampleDocument()
        let body = HTTPBody(
            mode: .formData,
            raw: RawBody(text: "{}", contentType: "application/json"),
            formData: [MultipartField(key: "avatar", kind: .file, file: .relative("avatar.png"), contentType: "image/png", isEnabled: false)],
            urlEncoded: [KeyValuePair(key: "a", value: "b")],
            binary: BinaryBody(file: .local(LocalPathID()), contentType: "application/octet-stream"),
            graphQL: GraphQLBody(query: "{ me }", variables: "{}", operationName: "Me")
        )
        let upload = RequestItem(name: "Upload", kind: .http(HTTPRequestSpec(
            method: .put,
            url: "https://upload",
            disabledAutoHeaders: ["User-Agent"],
            body: body,
            auth: .basic(username: "u", password: "p"),
            options: HTTPRequestOptions(timeoutSeconds: 5, followRedirects: false, verifyTLS: false)
        )))
        document.items.append(.request(upload))
        let identity = ClientCertificateSource.pem(certificate: .relative("c.pem"), key: .local(LocalPathID()))
        document.tls = ProjectTLSConfiguration(
            clientCertificates: [ClientCertificateEntry(hostPattern: "*.example.com", source: identity)],
            caCertificates: [.relative("ca.pem")]
        )
        document.grpc = ProjectGRPCConfiguration(protoRoots: [.relative("protos")], protoFiles: ["echo.proto"], descriptorSets: [.relative("set.pb")])
        return document
    }

    /// The key paths a payload can hold are the schema an older Mac may not understand: change them, and bump
    /// `ProjectRecordCoder.schemaVersion` with this fingerprint, so an older Mac defers those records rather than strip them.
    func testThePayloadSchemaMatchesItsVersion() throws {
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
        for record in try ProjectRecordCoder.records(for: richDocument(), secrets: [:]).values {
            collect(record.payload, into: &keys[record.type, default: []], path: "")
        }
        let schema = keys.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \($0.value.sorted().joined(separator: " "))" }
            .joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(schema.utf8)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(ProjectRecordCoder.schemaVersion, 1)
        let expected = "9181156f8e1f49d52864750c4d0069e3686263d8de48790ebc293c472f84b0b4"
        XCTAssertEqual(fingerprint, expected, "The payload keys are now:\n\(schema)\nBump the schema version, then set this to \(fingerprint).")
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
