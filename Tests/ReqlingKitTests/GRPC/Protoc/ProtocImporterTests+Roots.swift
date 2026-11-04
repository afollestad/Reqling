import Foundation
@testable import ReqlingKit
import XCTest

/// Roots reached through symlinks compile exactly as their targets would.
extension ProtocImporterTests {
    func testASymlinkedRootAndARootUnderASymlinkedParentCompileAndCache() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let real = directory.file("real")
        _ = try ProtocFixtures.copyRoots(["api", "common"], into: real)
        // `protos -> real/api`, and `cloud -> real` standing in for a linked folder such as `~/Dropbox`.
        let linkedRoot = directory.file("protos")
        let linkedParent = directory.file("cloud")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: real.appendingPathComponent("api"))
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: real)
        let roots = [linkedRoot, linkedParent.appendingPathComponent("common")]
        let runner = StubCommandRunner.recordingProcesses()
        let importer = makeImporter(runner: runner)

        let gathered = try await importer.compile(ProtocCompileInput(roots: roots), with: protoc)
        let named = try await importer.compile(ProtocCompileInput(roots: roots, files: ["acme/api/v1/greeter.proto"]), with: protoc)
        _ = try await importer.compile(ProtocCompileInput(roots: roots), with: protoc)

        XCTAssertEqual(gathered.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertEqual(named.services.map(\.fullName), ["acme.api.v1.Greeter"])
        // Fresh copies are cacheable only through their pre-launch digests, which must key the way `resolve` does.
        XCTAssertEqual(runner.invocations.count, 2, "the repeated compile is a cache hit")
    }

    func testANestedRootReachedThroughALinkStillOwnsItsFiles() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let real = directory.file("real")
        _ = try ProtocFixtures.copyRoots(["api", "common"], into: real)
        let linked = directory.file("cloud")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let roots = [linked, linked.appendingPathComponent("api"), real.appendingPathComponent("common")]

        let registry = try await makeImporter().compile(ProtocCompileInput(roots: roots), with: protoc)

        XCTAssertEqual(registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertNil(registry.file(named: "api/acme/api/v1/greeter.proto"))
    }
}
