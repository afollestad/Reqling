import Foundation
@testable import ReqlingKit
import XCTest

/// The compile cache must never serve a schema that differs from what protoc would compile now.
extension ProtocImporterTests {
    func testAnEditReachedThroughAFolderLinkInvalidatesTheCache() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let root = directory.file("protos/main")
        let vendor = directory.file("vendor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("third_party"), withDestinationURL: vendor)
        let dependency = vendor.appendingPathComponent("dep.proto")
        try #"syntax = "proto3"; package dep; message Dep { string a = 1; }"#.write(to: dependency, atomically: true, encoding: .utf8)
        // Older than the launch, so the first compile is cacheable even though the walk never sees this file.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: dependency.path)
        let main = #"syntax = "proto3"; package main; import "third_party/dep.proto"; message Main { dep.Dep dep = 1; }"#
        try main.write(to: root.appendingPathComponent("main.proto"), atomically: true, encoding: .utf8)
        let runner = StubCommandRunner.recordingProcesses()
        let importer = makeImporter(runner: runner)
        let input = ProtocCompileInput(roots: [root])

        _ = try await importer.compile(input, with: protoc)
        _ = try await importer.compile(input, with: protoc)
        XCTAssertEqual(runner.invocations.count, 1, "unchanged, so the second compile is a cache hit")

        try #"syntax = "proto3"; package dep; message Dep { string a = 1; string b = 2; }"#.write(to: dependency, atomically: true, encoding: .utf8)
        let recompiled = try await importer.compile(input, with: protoc)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(recompiled.message("dep.Dep")?.field.map(\.name), ["a", "b"])
    }

    func testAnEditDuringTheCompileIsNotCached() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        let types = roots[1].appendingPathComponent("acme/common/v1/types.proto")
        let real = ProcessCommandRunner()
        let first = FirstCall()
        // Lands after protoc read the file but before the importer stores its result.
        let runner = StubCommandRunner { invocation in
            let result = try await real.run(
                invocation.executable,
                arguments: invocation.arguments,
                currentDirectory: invocation.currentDirectory,
                timeout: .seconds(60)
            )
            if first.take() {
                let edited = try String(contentsOf: types, encoding: .utf8)
                    .replacingOccurrences(of: "string region = 2;", with: "string region = 2;\n  string script = 3;")
                try edited.write(to: types, atomically: true, encoding: .utf8)
            }
            return result
        }
        let importer = makeImporter(runner: runner)
        let input = ProtocCompileInput(roots: roots)

        let during = try await importer.compile(input, with: protoc)
        let after = try await importer.compile(input, with: protoc)

        XCTAssertEqual(during.message("acme.common.v1.Locale")?.field.map(\.name), ["language", "region"])
        XCTAssertEqual(runner.invocations.count, 2, "the first result was not stored")
        XCTAssertEqual(after.message("acme.common.v1.Locale")?.field.map(\.name), ["language", "region", "script"])
    }

    func testAnExplicitRecompileBypassesTheCache() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        let runner = StubCommandRunner.recordingProcesses()
        let importer = makeImporter(runner: runner)
        let input = ProtocCompileInput(roots: roots)

        _ = try await importer.compile(input, with: protoc)
        _ = try await importer.compile(input, with: protoc, reusingCache: false)
        _ = try await importer.compile(input, with: protoc)

        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testPendingFilesACrashLeftBehindArePruned() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        let cache = directory.file("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let abandoned = cache.appendingPathComponent(".pending-abandoned.binpb")
        let inFlight = cache.appendingPathComponent(".pending-in-flight.binpb")
        try Data().write(to: abandoned)
        try Data().write(to: inFlight)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: abandoned.path)

        _ = try await makeImporter().compile(ProtocCompileInput(roots: roots), with: protoc)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path), "another compile may still own a recent one")
    }
}
