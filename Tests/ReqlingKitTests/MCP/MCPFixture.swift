import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// The MCP tools over a temporary library, preferences and secrets in memory, a directory trash, no protoc, and a
/// stub window, dispatched the way the server dispatches them.
@MainActor
final class MCPFixture {
    let storage: LibraryFixture
    let workspace: WorkspaceStateStore
    let settings: SettingsStore
    let runner: RequestRunner
    let batches: BatchRunner
    let protoWorkspaces: ProtoWorkspaceStore
    let context: MCPToolContext
    let dispatcher: MCPToolDispatcher
    let host = StubMCPHost()

    /// `sleep` times out tool calls; `runnerSleep` waits out an event stream's reconnects and time limit.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        runnerSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        storage = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: storage.directory.file("Support/workspace.json"))
        settings = SettingsStore(preferences: MemoryPreferences())
        protoWorkspaces = ProtoWorkspaceStore(environment: ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: storage.directory.file("Support/ProtocCache")),
            locateProtoc: { nil },
            changes: { _ in AsyncStream { $0.finish() } }
        ))
        runner = RequestRunner(
            library: storage.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            history: RunHistory(directory: storage.directory.file("Support/History"), settings: settings),
            userAgent: "Reqling/1.0",
            grpcSchemas: GRPCSchemaService(workspaces: protoWorkspaces),
            graphQLSchemas: GraphQLSchemaService(
                store: GraphQLSchemaStore(directory: storage.directory.file("Support/GraphQLSchemas")),
                fetcher: LiveGraphQLIntrospectionFetcher()
            ),
            scripts: ScriptFixtures.realRunner,
            sleep: runnerSleep
        )
        batches = BatchRunner(runner: runner, sleep: runnerSleep)
        context = MCPToolContext(
            library: storage.library,
            workspace: workspace,
            runner: runner,
            batches: batches,
            settings: settings,
            protoWorkspaces: protoWorkspaces,
            appInfo: AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling.tests", version: "1.0.0", build: "1")
        )
        context.host = host
        dispatcher = MCPToolDispatcher(context: context, sleep: sleep)
    }

    var library: ProjectLibrary {
        storage.library
    }

    func cleanUp() {
        protoWorkspaces.retain(only: [])
        storage.directory.remove()
    }

    func call(_ name: String, _ arguments: [String: Value] = [:]) async -> MCPToolResult {
        await dispatcher.call(name, arguments: arguments)
    }

    /// The structured result of a call that must succeed.
    func success(
        _ name: String,
        _ arguments: [String: Value] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Value] {
        let result = await call(name, arguments)
        XCTAssertFalse(result.isError, "\(name) failed: \(result.text)", file: file, line: line)
        guard case .object(let object)? = result.structuredContent else {
            XCTFail("\(name) returned no object: \(result.text)", file: file, line: line)
            return [:]
        }
        // Both through JSON, which reads an integral double back as an integer.
        let roundTripped = try JSONDecoder().decode(Value.self, from: try JSONEncoder().encode(result.structuredContent))
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: Data(result.text.utf8)), roundTripped, "The text repeats the data")
        return object
    }

    /// The message of a call that must fail.
    func failure(_ name: String, _ arguments: [String: Value] = [:], file: StaticString = #filePath, line: UInt = #line) async -> String {
        let result = await call(name, arguments)
        XCTAssertTrue(result.isError, "\(name) should have failed: \(result.text)", file: file, line: line)
        return result.text
    }

    /// A project created through the tools, with its ID.
    func makeProject(_ name: String = "API") async throws -> ProjectID {
        let created = try await success("create_project", ["name": .string(name)])
        return try XCTUnwrap(created["project"]?.objectValue?["id"]?.stringValue.flatMap(ProjectID.init(string:)))
    }

    func document(_ project: ProjectID) throws -> ProjectDocument {
        try XCTUnwrap(library.document(project))
    }
}

@MainActor
final class StubMCPHost: MCPAppHost {
    private(set) var flushes = 0
    private(set) var revealed: [(ProjectID, RequestNodeID?)] = []
    var selectedItem: (project: ProjectID, node: RequestNodeID?)?
    var protoc: MCPProtocStatus = .missing

    func flushPendingEdits() {
        flushes += 1
    }

    func reveal(_ project: ProjectID, node: RequestNodeID?) {
        revealed.append((project, node))
    }

    func protocStatus() async -> MCPProtocStatus {
        protoc
    }

    func installProtoc() async throws -> ProtocInstallation {
        throw MCPToolError("Tests never install protoc.")
    }
}

extension Value {
    subscript(key: String) -> Value? {
        objectValue?[key]
    }
}
