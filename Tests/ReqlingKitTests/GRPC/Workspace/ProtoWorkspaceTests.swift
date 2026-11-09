import Foundation
@testable import ReqlingKit
import XCTest

@MainActor
final class ProtoWorkspaceTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var feed: ChangeFeed!
    private var sleeper: ManualSleeper!
    private var protoc: ProtocInstallation?
    private let compiledAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let codecService = "reqling.test.v1.EchoService"

    override func setUp() async throws {
        directory = try TemporaryDirectory()
        feed = ChangeFeed()
        sleeper = ManualSleeper()
        protoc = try await ProtocFixtures.requireProtoc()
        _ = try ProtocFixtures.copyRoots(["api", "common"], into: project.appendingPathComponent("protos"))
        let schema = project.appendingPathComponent("schema", isDirectory: true)
        try FileManager.default.createDirectory(at: schema, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ProtocFixtures.codecDescriptorSet, to: schema.appendingPathComponent("codec_test.binpb"))
    }

    override func tearDown() async throws {
        directory.remove()
    }

    /// A fourth service, written mid-test to stand in for an edit under a root.
    private static let pinger = """
    syntax = "proto3";
    package acme.api.v1;
    import "google/protobuf/empty.proto";
    service Pinger { rpc Ping(google.protobuf.Empty) returns (google.protobuf.Empty); }
    """

    private var project: URL {
        directory.file("project")
    }

    private var fullConfiguration: ProjectGRPCConfiguration {
        ProjectGRPCConfiguration(
            protoRoots: [.relative("protos/api"), .relative("protos/common")],
            descriptorSets: [.relative("schema/codec_test.binpb")]
        )
    }

    func testRootsCompileAndDescriptorSetsMergeIn() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        XCTAssertEqual(workspace.status, .compiling)

        await settle(workspace)

        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt))
        XCTAssertEqual(workspace.registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit", codecService])
        XCTAssertEqual(feed.watched.map { $0.map(\.lastPathComponent) }, [["api", "common", "codec_test.binpb"]])
    }

    func testWithoutProtocDescriptorSetsStillLoad() async throws {
        protoc = nil
        let workspace = makeWorkspace(fullConfiguration)

        await settle(workspace)

        XCTAssertEqual(workspace.status, .needsProtoc)
        XCTAssertEqual(workspace.registry.services.map(\.fullName), [codecService])
    }

    func testMissingPathsAreReportedAndWhatIsPresentStillLoads() async throws {
        let configuration = ProjectGRPCConfiguration(
            protoRoots: [.relative("protos/api"), .relative("protos/common"), .relative("protos/gone"), .local(LocalPathID())],
            descriptorSets: [.relative("schema/none.binpb")]
        )
        let workspace = makeWorkspace(configuration)

        await settle(workspace)

        XCTAssertEqual(workspace.status, .missingPaths(["“protos/gone”", "A file chosen on another Mac", "“schema/none.binpb”"]))
        XCTAssertEqual(workspace.registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])

        let filtered = makeWorkspace(ProjectGRPCConfiguration(protoRoots: [.relative("protos/api"), .relative("protos/common")], protoFiles: [
            "acme/api/v1/greeter.proto", "acme/api/v1/nope.proto"
        ]))
        await settle(filtered)
        XCTAssertEqual(filtered.status, .missingPaths(["“acme/api/v1/nope.proto”"]))
        XCTAssertEqual(filtered.registry.services.map(\.fullName), ["acme.api.v1.Greeter"])
    }

    func testARelativePathOutsideTheProjectIsMissingButAThisMacPathIsNot() async throws {
        let outside = try ProtocFixtures.copyRoots(["common"], into: directory.file("elsewhere"))[0]
        let localID = LocalPathID()
        let resolver = ProjectPathResolver(projectRoot: project, localPaths: [localID: outside.path], choices: [.local(localID): [.protoRoots]])
        let shared = ProtoWorkspace(
            projectID: ProjectID(),
            configuration: ProjectGRPCConfiguration(
                protoRoots: [.relative("protos/api"), .relative("../elsewhere/common")],
                descriptorSets: [.relative("../project/schema/../../project/schema/codec_test.binpb"), .relative("../../codec.binpb")]
            ),
            resolver: resolver,
            environment: makeEnvironment()
        )
        await settle(shared)

        let suffix = " (outside the project’s folder and repository)"
        XCTAssertEqual(shared.status, .missingPaths(["“../elsewhere/common”\(suffix)", "“../../codec.binpb”\(suffix)"]))
        XCTAssertEqual(feed.watched.last?.map(\.lastPathComponent), ["api", "codec_test.binpb"], "nothing outside is watched")

        let chosen = ProtoWorkspace(
            projectID: ProjectID(),
            configuration: ProjectGRPCConfiguration(protoRoots: [.relative("protos/api"), .local(localID)]),
            resolver: resolver,
            environment: makeEnvironment()
        )
        await settle(chosen)
        XCTAssertEqual(chosen.status, .ready(serviceCount: 2, compiledAt: compiledAt))
    }

    func testRecompileBypassesTheCacheAndAFileEventDoesNot() async throws {
        let runner = StubCommandRunner.recordingProcesses()
        let workspace = makeWorkspace(fullConfiguration, runner: runner)
        await settle(workspace)

        let debounced = expectation(description: "debounce")
        sleeper.expectSleep(debounced)
        feed.send()
        await fulfillment(of: [debounced], timeout: 10)
        sleeper.advance()
        await settle(workspace)
        XCTAssertEqual(runner.invocations.count, 1, "nothing changed, so the cache answers")

        workspace.recompile()
        await settle(workspace)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt))
    }

    func testAFileChangeRecompilesOnceTheDebounceElapses() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        await settle(workspace)
        try Self.pinger.write(to: project.appendingPathComponent("protos/api/acme/api/v1/pinger.proto"), atomically: true, encoding: .utf8)

        let firstSleep = expectation(description: "first debounce")
        sleeper.expectSleep(firstSleep)
        feed.send()
        await fulfillment(of: [firstSleep], timeout: 10)
        let secondSleep = expectation(description: "second debounce")
        sleeper.expectSleep(secondSleep)
        feed.send()
        await fulfillment(of: [secondSleep], timeout: 10)

        XCTAssertEqual(sleeper.cancelledCount, 1, "a second change restarts the debounce")
        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt), "nothing recompiles during the debounce")
        sleeper.advance()
        await settle(workspace)

        XCTAssertEqual(workspace.status, .ready(serviceCount: 4, compiledAt: compiledAt))
        XCTAssertNotNil(workspace.registry.service("acme.api.v1.Pinger"))
    }

    func testSettledWaitsForADebounceThatReplacedTheOneItWasAwaiting() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        await settle(workspace)
        try Self.pinger.write(to: project.appendingPathComponent("protos/api/acme/api/v1/pinger.proto"), atomically: true, encoding: .utf8)
        let firstSleep = expectation(description: "first debounce")
        sleeper.expectSleep(firstSleep)
        feed.send()
        await fulfillment(of: [firstSleep], timeout: 10)

        let returned = expectation(description: "settled")
        let waiter = Task { () -> ProtoWorkspace.Status in
            await workspace.settled()
            returned.fulfill()
            return workspace.status
        }
        // Lets the waiter start awaiting the first debounce before the second event replaces it.
        await Task.yield()
        let secondSleep = expectation(description: "second debounce")
        sleeper.expectSleep(secondSleep)
        feed.send()
        await fulfillment(of: [secondSleep], timeout: 10)
        sleeper.advance()
        await fulfillment(of: [returned], timeout: 30)

        let status = await waiter.value
        XCTAssertEqual(status, .ready(serviceCount: 4, compiledAt: compiledAt))
    }

    func testSettledReturnsWhileChangesNeverGoQuiet() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        await settle(workspace)
        // Every debounce that starts is replaced by a fresh change before it can elapse, like autosave on a timer.
        let feed = feed!
        sleeper.onEverySleep {
            Task { @MainActor in feed.send() }
        }
        defer { sleeper.onEverySleep(nil) }
        let editing = expectation(description: "first debounce")
        sleeper.expectSleep(editing)
        feed.send()
        await fulfillment(of: [editing], timeout: 10)

        await settle(workspace)

        XCTAssertGreaterThan(sleeper.cancelledCount, 0, "the debounce kept being replaced")
        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt), "the latest published schema")
    }

    func testSkippedFileNamesArePublishedAsWarningsBesideAReadyStatus() async throws {
        try Data("syntax = \"proto3\";\n".utf8).write(to: project.appendingPathComponent("protos/api/-ofile.proto"))
        let workspace = makeWorkspace(fullConfiguration)

        await settle(workspace)

        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt))
        XCTAssertEqual(workspace.warnings.map(\.severity), [.warning])
    }

    func testASyntaxErrorReportsDiagnosticsAndKeepsThePreviousServices() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        await settle(workspace)
        let greeter = project.appendingPathComponent("protos/api/acme/api/v1/greeter.proto")
        let broken = try String(contentsOf: greeter, encoding: .utf8).replacingOccurrences(of: "string name = 1;", with: "string name = 1")
        try broken.write(to: greeter, atomically: true, encoding: .utf8)

        workspace.recompile()
        await settle(workspace)

        guard case .failed(let diagnostics) = workspace.status else {
            return XCTFail("Expected a failure, got \(workspace.status)")
        }
        XCTAssertEqual(diagnostics.first?.file, "acme/api/v1/greeter.proto")
        XCTAssertNotNil(diagnostics.first?.line)
        XCTAssertEqual(workspace.registry.services.count, 3)
    }

    func testAConfigurationChangeRecompilesAndAnIdenticalOneDoesNot() async throws {
        let workspace = makeWorkspace(fullConfiguration)
        await settle(workspace)
        let resolver = ProjectPathResolver(projectRoot: project)

        workspace.update(configuration: fullConfiguration, resolver: resolver)
        XCTAssertEqual(workspace.status, .ready(serviceCount: 3, compiledAt: compiledAt))
        XCTAssertEqual(feed.watched.count, 1)

        workspace.update(configuration: ProjectGRPCConfiguration(protoRoots: fullConfiguration.protoRoots), resolver: resolver)
        XCTAssertEqual(workspace.status, .compiling)
        await settle(workspace)

        XCTAssertEqual(workspace.registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertEqual(feed.watched.last?.map(\.lastPathComponent), ["api", "common"])
        XCTAssertEqual(feed.terminationCount, 1, "the old watch ends")

        workspace.update(configuration: ProjectGRPCConfiguration(), resolver: resolver)
        await settle(workspace)
        XCTAssertEqual(workspace.status, .empty)
        XCTAssertTrue(workspace.registry.isEmpty)
    }

    func testTheStoreReusesUpdatesAndDropsWorkspaces() async throws {
        let store = ProtoWorkspaceStore(environment: makeEnvironment())
        let resolver = ProjectPathResolver(projectRoot: project)
        let kept = ProjectID()
        let dropped = ProjectID()

        let workspace = store.workspace(for: kept, configuration: fullConfiguration, resolver: resolver)
        store.workspace(for: dropped, configuration: fullConfiguration, resolver: resolver)
        let setsOnly = ProjectGRPCConfiguration(descriptorSets: fullConfiguration.descriptorSets)
        let reused = store.workspace(for: kept, configuration: setsOnly, resolver: resolver)
        await settle(workspace)

        XCTAssertTrue(reused === workspace)
        XCTAssertEqual(workspace.registry.services.map(\.fullName), [codecService])
        store.retain(only: [kept])
        XCTAssertNil(store.workspace(for: dropped))
        XCTAssertTrue(store.workspace(for: kept) === workspace)
        XCTAssertEqual(feed.terminationCount, 2, "the replaced watch and the dropped project's watch both end")
    }

    private func makeWorkspace(_ configuration: ProjectGRPCConfiguration, runner: any CommandRunning = ProcessCommandRunner()) -> ProtoWorkspace {
        ProtoWorkspace(
            projectID: ProjectID(),
            configuration: configuration,
            resolver: ProjectPathResolver(projectRoot: project),
            environment: makeEnvironment(runner: runner)
        )
    }

    private func makeEnvironment(runner: any CommandRunning = ProcessCommandRunner()) -> ProtoWorkspaceEnvironment {
        let protoc = protoc
        let sleeper = sleeper!
        let feed = feed!
        let compiledAt = compiledAt
        return ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: directory.file("cache"), runner: runner),
            locateProtoc: { protoc },
            changes: { feed.stream(watching: $0) },
            sleep: { try await sleeper.sleep($0) },
            now: { compiledAt }
        )
    }

    /// `settled()` bounded, so a hang fails the test instead of stalling the suite.
    private func settle(_ workspace: ProtoWorkspace) async {
        let done = expectation(description: "settled")
        Task {
            await workspace.settled()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
    }
}
