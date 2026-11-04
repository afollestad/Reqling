import Foundation
@testable import ReqlingKit
import XCTest

/// Project-controlled paths become protoc arguments; none may be read as an option.
extension ProtocImporterTests {
    func testEntriesProtocCouldMisreadAreRejectedBeforeItRuns() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        // Real files at option-shaped paths, so an existence check alone would let them through.
        for path in ["-o\(directory.url.path)/pwned/x.proto", "@args/x.proto"] {
            let url = roots[0].appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let runner = StubCommandRunner.recordingProcesses()
        let hostile = [
            "-o\(directory.url.path)/pwned/x.proto", "@args/x.proto", "--descriptor_set_out=evil.binpb",
            "../common/acme/common/v1/types.proto", "/etc/hosts", "acme\\api\\v1\\greeter.proto", "acme/./api/v1/greeter.proto",
            "acme//api/v1/greeter.proto", "acme/api/v1/greeter.proto\n", "acme/api/v1/absent.proto"
        ]

        do {
            let input = ProtocCompileInput(roots: roots, files: ["acme/api/v1/greeter.proto"] + hostile)
            _ = try await makeImporter(runner: runner).compile(input, with: protoc)
            XCTFail("Expected the hostile entries to be rejected")
        } catch let failure as ProtocImportFailure {
            XCTAssertEqual(failure.diagnostics.count, hostile.count)
            XCTAssertTrue(failure.diagnostics.allSatisfy { $0.message.hasPrefix("Skipped ") && !$0.message.contains("\n") })
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.file("pwned").path))
    }

    func testUnsafeGatheredNamesAreSkippedWithAWarning() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        for name in ["-ofile.proto", "@args.proto", "bell\u{7}.proto"] {
            try Data("syntax = \"proto3\";\n".utf8).write(to: roots[0].appendingPathComponent(name))
        }
        let runner = StubCommandRunner.recordingProcesses()

        let result = try await makeImporter(runner: runner).compilation(ProtocCompileInput(roots: roots), with: protoc)

        XCTAssertEqual(result.registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertEqual(result.warnings.count, 3)
        XCTAssertTrue(result.warnings.allSatisfy { $0.severity == .warning && $0.message.hasPrefix("Skipped ") })
        runner.assertOnlyImporterOptions()
    }

    func testNamesWithFormatCharactersAreOrdinaryNames() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let root = directory.file("protos/names")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // ZWNJ (Persian), a ZWJ emoji sequence, and a soft hyphen: Unicode format characters, not control characters.
        let names = [
            "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0645}.proto",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.proto",
            "ex\u{00AD}ample.proto"
        ]
        for (index, name) in names.enumerated() {
            let source = "syntax = \"proto3\"; package names; message M\(index) {}"
            try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let gathered = try await makeImporter().compilation(ProtocCompileInput(roots: [root]), with: protoc)
        let named = try await makeImporter().compile(ProtocCompileInput(roots: [root], files: [names[0]]), with: protoc)

        XCTAssertTrue(gathered.warnings.isEmpty)
        XCTAssertEqual(names.indices.compactMap { gathered.registry.message("names.M\($0)")?.name }, ["M0", "M1", "M2"])
        XCTAssertNotNil(named.message("names.M0"))
    }

    func testAFolderProtocWouldSplitIsRejected() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let runner = StubCommandRunner.recordingProcesses()
        let colonRoot = try ProtocFixtures.copyRoots(["common"], into: directory.file("a:b"))

        do {
            _ = try await makeImporter(runner: runner).compile(ProtocCompileInput(roots: colonRoot), with: protoc)
            XCTFail("Expected the folder to be rejected")
        } catch let failure as ProtocImportFailure {
            XCTAssertEqual(failure.diagnostics.map(\.severity), [.error])
        }

        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testOnlyTheImportersOwnOptionsEverReachProtoc() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common", "broken"], into: directory.file("protos"))
        let runner = StubCommandRunner.recordingProcesses()
        let importer = makeImporter(runner: runner)
        let inputs = [
            ProtocCompileInput(roots: Array(roots.prefix(2))),
            ProtocCompileInput(roots: Array(roots.prefix(2)), files: ["acme/api/v1/greeter.proto"]),
            ProtocCompileInput(roots: roots, files: ["-I/", "acme/broken/v1/broken.proto"]),
            ProtocCompileInput(roots: [roots[2]])
        ]

        for input in inputs {
            _ = try? await importer.compile(input, with: protoc)
        }

        XCTAssertEqual(runner.invocations.count, 3, "the hostile input never ran")
        runner.assertOnlyImporterOptions()
    }
}
