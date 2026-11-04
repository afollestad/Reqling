import Foundation
@testable import ReqlingKit
import XCTest

final class ProtocImporterTests: XCTestCase {
    var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
    }

    func testEveryProtoUnderTwoRootsThatImportEachOtherCompiles() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))

        let registry = try await makeImporter().compile(ProtocCompileInput(roots: roots), with: protoc)

        XCTAssertEqual(registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertNotNil(registry.message("acme.common.v1.Locale"))
        XCTAssertNotNil(registry.enumType("acme.api.v1.Health"))
        XCTAssertNotNil(registry.message("google.protobuf.Timestamp"), "imports, well-known types included, are in the set")
        XCTAssertEqual(registry.method("acme.api.v1.Greeter/StreamHellos")?.kind, .serverStreaming)
    }

    func testEntryFilesLimitTheCompileToThemAndTheirImports() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))

        let input = ProtocCompileInput(roots: roots, files: ["acme/api/v1/greeter.proto"])
        let registry = try await makeImporter().compile(input, with: protoc)

        XCTAssertEqual(registry.services.map(\.fullName), ["acme.api.v1.Greeter"])
        XCTAssertNotNil(registry.file(named: "acme/common/v1/types.proto"))
        XCTAssertNil(registry.file(named: "acme/common/v1/audit.proto"))
    }

    func testANestedRootOwnsItsFiles() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let parent = directory.file("protos")
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: parent)

        let registry = try await makeImporter().compile(ProtocCompileInput(roots: [parent] + roots), with: protoc)

        XCTAssertEqual(registry.services.map(\.fullName), ["acme.api.v1.Greeter", "acme.common.v1.Audit"])
        XCTAssertNil(registry.file(named: "api/acme/api/v1/greeter.proto"))
    }

    func testASyntaxErrorSurfacesAsAPositionedDiagnostic() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["broken"], into: directory.file("protos"))

        do {
            _ = try await makeImporter().compile(ProtocCompileInput(roots: roots), with: protoc)
            XCTFail("Expected a syntax error")
        } catch let failure as ProtocImportFailure {
            let diagnostic = try XCTUnwrap(failure.diagnostics.first)
            XCTAssertEqual(diagnostic.file, "acme/broken/v1/broken.proto")
            XCTAssertEqual(diagnostic.line, 8)
            XCTAssertEqual(diagnostic.column, 3)
            XCTAssertEqual(diagnostic.severity, .error)
            let expected = roots[0].appendingPathComponent("acme/broken/v1/broken.proto")
            XCTAssertEqual(diagnostic.url?.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath())
        }
    }

    func testAnUnchangedSchemaSkipsProtocAndAProtoEditRecompiles() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let roots = try ProtocFixtures.copyRoots(["api", "common"], into: directory.file("protos"))
        let runner = StubCommandRunner.recordingProcesses()
        let importer = makeImporter(runner: runner)
        let input = ProtocCompileInput(roots: roots)

        _ = try await importer.compile(input, with: protoc)
        try Data("notes".utf8).write(to: roots[0].appendingPathComponent("README.md"))
        let cached = try await importer.compile(input, with: protoc)
        XCTAssertEqual(runner.invocations.count, 1, "a non-proto file does not invalidate the cache")
        XCTAssertEqual(cached.services.count, 2)

        let types = roots[1].appendingPathComponent("acme/common/v1/types.proto")
        let edited = try String(contentsOf: types, encoding: .utf8)
            .replacingOccurrences(of: "string region = 2;", with: "string region = 2;\n  string script = 3;")
        try edited.write(to: types, atomically: true, encoding: .utf8)
        let recompiled = try await importer.compile(input, with: protoc)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(recompiled.message("acme.common.v1.Locale")?.field.map(\.name), ["language", "region", "script"])
        _ = try await makeImporter(runner: runner).compile(ProtocCompileInput(roots: roots, files: ["acme/api/v1/greeter.proto"]), with: protoc)
        XCTAssertEqual(runner.invocations.count, 3, "different arguments are a different schema")
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(1)), ["--include_imports"])
        XCTAssertTrue(arguments[1].hasPrefix("--descriptor_set_out="))
        XCTAssertEqual(Array(arguments.suffix(1)), ["acme/api/v1/greeter.proto"])
    }

    func testNoProtoFilesFailsWithoutRunningProtoc() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let empty = directory.file("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let runner = StubCommandRunner.recordingProcesses()

        do {
            _ = try await makeImporter(runner: runner).compile(ProtocCompileInput(roots: [empty]), with: protoc)
            XCTFail("Expected a failure")
        } catch let failure as ProtocImportFailure {
            XCTAssertEqual(failure.diagnostics.count, 1)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testStderrParsingKeepsPositionsSeverityAndRawLines() {
        let root = directory.file("root")
        let output = """
        \(root.path)/a/b.proto:3:14: "Foo" is not defined.
        a/c.proto:1:1: warning: Import a/d.proto is unused.
        Could not make proto path relative: a/x.proto: No such file or directory

        """

        let diagnostics = ProtocDiagnostic.parse(output, roots: [root])

        XCTAssertEqual(diagnostics.map(\.description), [
            #"a/b.proto:3:14: "Foo" is not defined."#,
            "a/c.proto:1:1: Import a/d.proto is unused.",
            "Could not make proto path relative: a/x.proto: No such file or directory"
        ])
        XCTAssertEqual(diagnostics.map(\.severity), [.error, .warning, .error])
        XCTAssertEqual(diagnostics[0].url?.path, root.appendingPathComponent("a/b.proto").path)
        XCTAssertNil(diagnostics[2].file)
    }

    func makeImporter(runner: any CommandRunning = ProcessCommandRunner()) -> ProtocImporter {
        ProtocImporter(cacheDirectory: directory.file("cache"), runner: runner)
    }
}
