import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

/// One `CommandRunning.run` call.
struct CommandInvocation: Hashable, Sendable {
    let executable: URL
    let arguments: [String]
    let currentDirectory: URL?
}

/// Answers every launch from `handler` and records it, so tests assert exactly which tools ran.
final class StubCommandRunner: CommandRunning {
    private let handler: @Sendable (CommandInvocation) async throws -> CommandResult
    private let calls = Mutex<[CommandInvocation]>([])

    init(handler: @escaping @Sendable (CommandInvocation) async throws -> CommandResult) {
        self.handler = handler
    }

    /// Passes every launch to the real runner, so a protoc test can count how often protoc actually ran.
    static func recordingProcesses() -> StubCommandRunner {
        let runner = ProcessCommandRunner()
        return StubCommandRunner { invocation in
            try await runner.run(
                invocation.executable,
                arguments: invocation.arguments,
                currentDirectory: invocation.currentDirectory,
                timeout: .seconds(60)
            )
        }
    }

    /// Answers `--version` with `libprotoc <version>` for the listed paths and fails everything else.
    static func protocVersions(_ versions: [String: String]) -> StubCommandRunner {
        StubCommandRunner { invocation in
            guard invocation.arguments == ["--version"], let version = versions[invocation.executable.path] else {
                return CommandResult(exitCode: 1)
            }
            return CommandResult(exitCode: 0, standardOutput: Data("libprotoc \(version)\n".utf8))
        }
    }

    var invocations: [CommandInvocation] {
        calls.withLock { $0 }
    }

    func run(_ executable: URL, arguments: [String], currentDirectory: URL?, timeout: Duration) async throws -> CommandResult {
        let invocation = CommandInvocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        calls.withLock { $0.append(invocation) }
        return try await handler(invocation)
    }
}

/// A file system made of path sets, for staging Homebrew, managed, and `PATH` layouts.
struct FakeProtocFileSystem: ProtocFileSystem {
    var executables: Set<String> = []
    var files: Set<String> = []
    var directories: [String: [String]] = [:]
    var symlinks: [String: String] = [:]

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    func fileExists(atPath path: String) -> Bool {
        files.contains(path) || executables.contains(path) || directories[path] != nil
    }

    func contentsOfDirectory(atPath path: String) -> [String] {
        directories[path] ?? []
    }

    func resolvingSymlinks(inPath path: String) -> String {
        symlinks[path] ?? path
    }
}

/// Thrown when the protoc `scripts/setup.sh` installs is missing, failing the test rather than skipping it.
struct ProtocSetupRequired: LocalizedError, CustomStringConvertible {
    var description: String {
        "protoc with its well-known types was not found; run ./scripts/setup.sh"
    }

    var errorDescription: String? {
        description
    }
}

enum ProtocFixtures {
    /// The real protoc, found the way the app finds it but with no managed install.
    static func requireProtoc() async throws -> ProtocInstallation {
        let noTools = FileManager.default.temporaryDirectory.appendingPathComponent("ReqlingKitTests/no-tools-\(UUID().uuidString)")
        guard let protoc = try await ProtocLocator(toolsDirectory: noTools).locate(overridePath: nil), protoc.includeDirectory != nil else {
            throw ProtocSetupRequired()
        }
        return protoc
    }

    /// `Fixtures/Protos/workspace`: the `api` and `common` roots import each other; `broken` has a syntax error.
    static var workspace: URL {
        get throws {
            let url = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Protos/workspace", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return url
        }
    }

    static var codecDescriptorSet: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "codec_test", withExtension: "binpb", subdirectory: "Fixtures"))
        }
    }

    /// Copies the named fixture roots into `directory`, so a test can edit them without touching the bundle.
    static func copyRoots(_ names: [String], into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try names.map { name in
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: workspace.appendingPathComponent(name, isDirectory: true), to: destination)
            return destination
        }
    }
}

/// True for the first caller only, for a stub that must act once however often it runs.
final class FirstCall: Sendable {
    private let pending = Mutex(true)

    func take() -> Bool {
        pending.withLock { pending in
            defer { pending = false }
            return pending
        }
    }
}

extension StubCommandRunner {
    /// Fails when protoc received an argument starting with `-` or `@` that the importer did not choose itself.
    func assertOnlyImporterOptions(file: StaticString = #filePath, line: UInt = #line) {
        let chosen = ["--include_imports", "--descriptor_set_out=", "--proto_path="]
        for argument in invocations.flatMap(\.arguments) where argument.hasPrefix("-") || argument.hasPrefix("@") {
            XCTAssertTrue(chosen.contains { argument == $0 || ($0.hasSuffix("=") && argument.hasPrefix($0)) }, argument, file: file, line: line)
        }
    }
}
