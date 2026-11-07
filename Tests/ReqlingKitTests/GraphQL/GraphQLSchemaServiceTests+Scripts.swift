import Foundation
import Synchronization
@testable import ReqlingKit
import XCTest

/// Introspection runs the request's pre-request scripts in preview, only when it asks the server.
@MainActor
extension GraphQLSchemaServiceTests {
    func testIntrospectionRunsPreRequestScriptsOnlyWhenItAsksTheServer() async throws {
        let server = try await start(.init(requiredBearerToken: "from-script"))
        let setup = try makeProject(base: server.url.absoluteString)
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) { request in
                if var spec = request.kind.httpSpec {
                    spec.headers.append(KeyValuePair(key: "Authorization", value: "Bearer {{auth}}"))
                    request.kind = .http(spec)
                }
                request.scripts.preRequest = """
                rq.variables.set("auth", "from-script")
                rq.request.query.upsert("ts", String(Date.now()))
                rq.environment.set("kept", "no")
                """
            }
        }
        let scripts = ScriptFixtures.countingRunner()
        let runner = makeRunner(scripts: scripts)

        var untrusted: RunFailure?
        do {
            _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        } catch {
            untrusted = error
        }
        workspace.updateProject(setup.project) { $0.scriptTrust = .trusted }
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)

        let note = "since this project's scripts aren't trusted on this Mac."
        XCTAssertTrue(untrusted?.message.hasSuffix(note) ?? false, "\(String(describing: untrusted))")
        XCTAssertTrue(untrusted?.message.contains("auth") ?? false, "Only the scripts define it")
        XCTAssertEqual(scripts.launches, 1, "A cached schema runs no scripts, though one changes the query each time")
        let defaultEnvironment = try XCTUnwrap(fixture.library.document(setup.project)).defaultEnvironment.id
        XCTAssertTrue(fixture.library.currentValues.values(in: .environment(setup.project, defaultEnvironment)).isEmpty)
    }

    /// A request whose script skips it still introspects: only a run skips.
    func testARequestWhoseScriptSkipsItStillIntrospects() async throws {
        let server = try await start(.init())
        let setup = try makeProject(base: server.url.absoluteString)
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) { $0.scripts.preRequest = "rq.execution.skipRequest()" }
        }
        workspace.updateProject(setup.project) { $0.scriptTrust = .trusted }

        let schema = try await makeRunner().graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertNotNil(schema.typeSystem.type(named: "Book"))
    }

    /// Introspection reads the project's certificates once when scripts leave the endpoint as it was, and again when
    /// one sends it elsewhere, so it never presents the first host's certificate to another.
    func testIntrospectionReadsCertificatesAgainOnlyForAnotherHost() async throws {
        let server = try await start(.init(tls: try TLSFixtures.serverContext(requireClientCertificate: true)))
        guard let port = server.url.port else {
            return XCTFail("The server has no port")
        }
        let setup = try makeProject(base: "https://{{host}}:\(port)/graphql")
        let projectURL = fixture.projectURL(setup.project)
        try FileManager.default.copyItem(at: TLSFixtures.url("client.p12"), to: projectURL.appendingPathComponent("client.p12"))
        try FileManager.default.copyItem(at: TLSFixtures.url("ca.pem"), to: projectURL.appendingPathComponent("ca.pem"))
        let entries = ["127.0.0.1", "localhost"].map { ClientCertificateEntry(hostPattern: $0, source: .pkcs12(.relative("client.p12"))) }
        try fixture.library.mutate(setup.project) { document in
            document.tls = ProjectTLSConfiguration(clientCertificates: entries, caCertificates: [.relative("ca.pem")])
            document.defaultEnvironment.variables.append(Variable(key: "host", value: "127.0.0.1"))
            try document.updateRequest(setup.request) { $0.scripts.preRequest = "rq.request.headers.upsert('X-Signed', 'yes')" }
        }
        for entry in entries {
            try fixture.library.setCertificatePassphrase(TLSFixtures.clientPassphrase, for: entry.id, in: setup.project)
        }
        workspace.updateProject(setup.project) { $0.scriptTrust = .trusted }
        let probe = CountingProbe()
        let runner = makeRunner(probe: probe)

        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        let unchanged = probe.checks
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) { $0.scripts.preRequest = "rq.variables.set('host', 'localhost')" }
        }
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project, refresh: true)

        XCTAssertEqual(unchanged, 1, "The script-free probe's certificates serve the request as scripts left it")
        XCTAssertEqual(probe.checks, unchanged + 2, "Another host gets its own certificates")
    }
}

/// `TLSFixtures.probe`, counting the certificate files it checks.
private final class CountingProbe: PKCS12ImportProbe {
    private let count = Mutex(0)

    var checks: Int {
        count.withLock { $0 }
    }

    func check(_ data: Data, passphrase: String) throws(TLSError) {
        count.withLock { $0 += 1 }
        try TLSFixtures.probe.check(data, passphrase: passphrase)
    }
}
