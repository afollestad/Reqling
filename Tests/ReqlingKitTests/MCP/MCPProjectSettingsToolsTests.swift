import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// Proto definitions, TLS settings, and app settings: the tools that write paths, Keychain values, and preferences.
@MainActor
final class MCPProjectSettingsToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var project: ProjectID!

    override func setUp() async throws {
        fixture = try MCPFixture()
        project = try await fixture.makeProject()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    private var projectArgument: Value {
        .string(project.description)
    }

    // MARK: - Proto definitions

    func testSharedPathsStayRelativeAndThisMacPathsNeverReachTheProject() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rq-protos-\(UUID().uuidString)").path
        let inside = fixture.storage.projectURL(project).appendingPathComponent("protos").path

        _ = try await fixture.success("update_proto_config", [
            "project": projectArgument,
            "protoRoots": [["path": .string(inside)], ["path": .string(outside), "local": true]],
            "protoFiles": ["acme/v1/users.proto", " "]
        ])
        let again = try await fixture.success("update_proto_config", [
            "project": projectArgument,
            "protoRoots": [["path": "protos"], ["path": .string(outside), "local": true]]
        ])
        let refused = await fixture.failure("update_proto_config", ["project": projectArgument, "protoRoots": [["path": .string(outside)]]])

        let grpc = try fixture.document(project).grpc
        XCTAssertEqual(grpc.protoRoots.first, .relative("protos"))
        XCTAssertEqual(grpc.protoFiles, ["acme/v1/users.proto"])
        XCTAssertEqual(fixture.workspace.localPaths(in: project).count, 1, "Repeating a this-Mac path reuses its entry")
        XCTAssertEqual(again["protoRoots"]?.arrayValue?.last?["path"], .string(outside))
        XCTAssertEqual(again["protoRoots"]?.arrayValue?.last?["shared"], false)
        XCTAssertFalse(try fixture.storage.contents("project.json", in: project).contains(outside))
        XCTAssertTrue(refused.contains("local: true"), refused)
    }

    func testADescriptorSetIsBrowsableWithoutProtoc() async throws {
        try FileManager.default.copyItem(
            at: try ProtocFixtures.codecDescriptorSet,
            to: fixture.storage.projectURL(project).appendingPathComponent("api.binpb")
        )

        let compiled = try await fixture.success("update_proto_config", ["project": projectArgument, "descriptorSets": [["path": "api.binpb"]]])
        let services = try await fixture.success("grpc_list_services", ["project": projectArgument])
        let method = try await fixture.success("grpc_describe_method", ["project": projectArgument, "rpc": "reqling.test.v1.EchoService/Unary"])
        let unknown = await fixture.failure("grpc_describe_method", ["project": projectArgument, "rpc": "nope.Service/Call"])

        XCTAssertEqual(compiled["status"]?["state"], "ready")
        let echo = try XCTUnwrap(services["services"]?.arrayValue?.first { $0["name"] == "reqling.test.v1.EchoService" })
        XCTAssertEqual(echo["methods"]?.arrayValue?.map { $0["name"] }, ["Unary", "ServerStream", "ClientStream", "Bidi"])
        XCTAssertEqual(method["kind"], "unary")
        XCTAssertEqual(method["input"]?["fields"]?.arrayValue?.map { $0["name"] }, ["text", "index"])
        XCTAssertEqual(method["exampleInput"]?.stringValue?.contains(#""text""#), true)
        XCTAssertTrue(unknown.contains("no method nope.Service/Call"), unknown)
    }

    func testProtocStatusComesFromTheWindow() async throws {
        let installation = ProtocInstallation(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/protoc"),
            source: .homebrew,
            version: "36.2",
            includeDirectory: nil
        )
        fixture.host.protoc = .found(installation)

        let status = try await fixture.success("get_protoc_status")

        XCTAssertEqual(status["found"], true)
        XCTAssertEqual(status["version"], "36.2")
    }

    // MARK: - TLS

    func testPassphrasesAreWriteOnlyAndGoWithTheirCertificate() async throws {
        let added = try await fixture.success("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["hostPattern": "*.internal", "file": ["path": "certs/client.p12"], "passphrase": "p4ss-phrase"]],
            "caCertificates": [["path": "certs/ca.pem"]]
        ])
        let entry = try XCTUnwrap(added["clientCertificates"]?.arrayValue?.first)
        let id = try XCTUnwrap(entry["id"]?.stringValue)
        let noFile = await fixture.failure("update_tls_config", ["project": projectArgument, "clientCertificates": [["hostPattern": "x"]]])

        XCTAssertEqual(entry["hasPassphrase"], true)
        XCTAssertEqual(entry["file"]?["relativePath"], "certs/client.p12")
        XCTAssertFalse(MCPJSON.text(.object(added)).contains("p4ss-phrase"))
        XCTAssertFalse(try fixture.storage.contents("project.json", in: project).contains("p4ss-phrase"))
        XCTAssertEqual(try fixture.document(project).tls.caCertificates, [.relative("certs/ca.pem")])
        XCTAssertTrue(noFile.contains("needs a `file`"), noFile)

        _ = try await fixture.success("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["id": .string(id), "hostPattern": "api.internal"]]
        ])
        XCTAssertEqual(try fixture.document(project).tls.clientCertificates.first?.hostPattern, "api.internal")
        let repeated = await fixture.failure("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["id": .string(id)], ["id": .string(id)]]
        ])
        XCTAssertTrue(repeated.contains("more than once"), repeated)
        XCTAssertEqual(try fixture.document(project).tls.clientCertificates.count, 1)
        XCTAssertNotNil(fixture.library.certificatePassphrase(for: try XCTUnwrap(CertificateEntryID(string: id)), in: project), "Kept by ID")

        _ = try await fixture.success("update_tls_config", ["project": projectArgument, "clientCertificates": []])
        XCTAssertNil(fixture.library.certificatePassphrase(for: try XCTUnwrap(CertificateEntryID(string: id)), in: project))
    }

    func testAPEMCertificateTakesItsCertificateAndKeyFiles() async throws {
        let added = try await fixture.success("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [[
                "hostPattern": "*.internal",
                "certificate": ["path": "certs/client.crt"],
                "key": ["path": "certs/client.key"],
                "passphrase": "k3y-phrase"
            ]]
        ])
        let entry = try XCTUnwrap(added["clientCertificates"]?.arrayValue?.first)
        let id = try XCTUnwrap(entry["id"]?.stringValue)

        XCTAssertEqual(entry["source"], "pem")
        XCTAssertEqual(entry["certificate"]?["relativePath"], "certs/client.crt")
        XCTAssertEqual(entry["key"]?["relativePath"], "certs/client.key")
        XCTAssertEqual(entry["hasPassphrase"], true)
        XCTAssertFalse(MCPJSON.text(.object(added)).contains("k3y-phrase"))

        _ = try await fixture.success("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["id": .string(id), "key": ["path": "certs/rotated.key"]]]
        ])
        XCTAssertEqual(
            try fixture.document(project).tls.clientCertificates.first?.source,
            .pem(certificate: .relative("certs/client.crt"), key: .relative("certs/rotated.key"))
        )

        let both = await fixture.failure("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["hostPattern": "x", "file": ["path": "a.p12"], "certificate": ["path": "a.crt"]]]
        ])
        let keyless = await fixture.failure("update_tls_config", [
            "project": projectArgument,
            "clientCertificates": [["hostPattern": "x", "certificate": ["path": "a.crt"]]]
        ])
        XCTAssertTrue(both.contains("not both"), both)
        XCTAssertTrue(keyless.contains("needs both"), keyless)
        XCTAssertEqual(try fixture.document(project).tls.clientCertificates.map(\.id.description), [id], "A refused update changes nothing")
    }

    // MARK: - App

    func testSettingsChangeWithinRangeAndNeverIncludeTheServer() async throws {
        let updated = try await fixture.success("update_settings", ["theme": "dark", "requestTimeoutSeconds": 45, "verifyTLS": false])
        let outOfRange = await fixture.failure("update_settings", ["grpcDeadlineSeconds": 9_000])
        let serverSetting = await fixture.failure("update_settings", ["mcpEnabled": false])

        XCTAssertEqual(updated["theme"], "dark")
        XCTAssertEqual(fixture.settings.settings.requestTimeoutSeconds, 45)
        XCTAssertFalse(fixture.settings.settings.verifyTLS)
        XCTAssertTrue(outOfRange.contains("must be from 1.0 to 600.0"), outOfRange)
        XCTAssertTrue(serverSetting.contains("unsupported field"), serverSetting)
    }

    func testUpdateToolsReportTheCheckAndNeverInstall() async throws {
        let notWired = await fixture.failure("get_update_status")
        let release = stubRelease("1.1.0", servedFrom: "example.test", bytes: Data())
        fixture.context.updates = AppUpdateManager(
            releaseClient: FixedLookup(.installable(AppUpdateReleaseFeed(latestRelease: release, releaseNotes: []))),
            currentVersion: "1.0.0"
        )

        let before = try await fixture.success("get_update_status")
        let checked = try await fixture.success("check_for_updates")

        XCTAssertTrue(notWired.contains("doesn't check for updates"), notWired)
        XCTAssertEqual(before["status"], "notChecked")
        XCTAssertEqual(before["currentVersion"], "1.0.0")
        XCTAssertEqual(checked["status"], "updateAvailable")
        XCTAssertEqual(checked["availableVersion"], "1.1.0")
        XCTAssertEqual(checked["releaseURL"], .string(release.htmlURL.absoluteString))
        XCTAssertFalse(fixture.dispatcher.definitions.contains { $0.name.contains("install_update") }, "Installing stays a window action")
    }

    func testRevealAndAppStateGoThroughTheWindow() async throws {
        let created = try await fixture.success("create_request", ["project": projectArgument, "name": "Ping"])
        let request = try XCTUnwrap(created["request"]?["id"]?.stringValue)
        fixture.host.selectedItem = (project, RequestNodeID(string: request))

        _ = try await fixture.success("reveal_item", ["project": projectArgument, "item": .string(request)])
        let state = try await fixture.success("get_app_state")

        XCTAssertEqual(fixture.host.revealed.first?.1?.description, request)
        XCTAssertEqual(state["selection"]?["itemName"], "Ping")
        XCTAssertEqual(state["app"]?["version"], "1.0.0")
    }
}

private struct FixedLookup: AppUpdateReleaseClient {
    let lookup: AppUpdateReleaseLookupResult

    init(_ lookup: AppUpdateReleaseLookupResult) {
        self.lookup = lookup
    }

    func latestRelease() async -> AppUpdateReleaseLookupResult {
        lookup
    }
}
