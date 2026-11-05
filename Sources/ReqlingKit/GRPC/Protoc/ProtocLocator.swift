import Foundation

/// Where a `protoc` came from, in the order `ProtocLocator` tries them.
public enum ProtocSource: String, Hashable, Sendable, CaseIterable {
    case settingsOverride
    case managed
    case homebrew
    case usrLocal
    case path
}

/// A runnable `protoc` and the well-known types that ship with it.
public struct ProtocInstallation: Hashable, Sendable {
    public let executable: URL
    public let source: ProtocSource
    /// As `protoc --version` reports it, without the `libprotoc ` prefix (`36.2`).
    public let version: String
    /// The directory holding `google/protobuf/*.proto` for this protoc. `nil` when none sits beside it; protoc then
    /// fails any import of a well-known type with its own "File not found" diagnostic.
    public let includeDirectory: URL?

    public init(executable: URL, source: ProtocSource, version: String, includeDirectory: URL?) {
        self.executable = executable
        self.source = source
        self.version = version
        self.includeDirectory = includeDirectory
    }
}

/// The Settings path override names something that is not a working protoc.
public struct ProtocLocatorError: Error, Hashable, Sendable, LocalizedError {
    public let path: String
    public let reason: String

    public var errorDescription: String? {
        "The protoc set in Settings (\((path as NSString).abbreviatingWithTildeInPath)) \(reason)."
    }
}

/// The file system checks `ProtocLocator` makes, so tests can stage Homebrew and `PATH` layouts without touching them.
public protocol ProtocFileSystem: Sendable {
    /// A regular file this user may execute; a directory never counts.
    func isExecutableFile(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
    /// Entry names, or empty when `path` is not a readable directory.
    func contentsOfDirectory(atPath path: String) -> [String]
    func resolvingSymlinks(inPath path: String) -> String
}

public struct LocalProtocFileSystem: ProtocFileSystem {
    public init() {}

    public func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func resolvingSymlinks(inPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Finds `protoc`: the Settings override, then Reqling's managed install, then Homebrew on Apple silicon and Intel,
/// then `PATH`.
///
/// The fixed Homebrew locations come before `PATH` because an app launched from the Dock inherits only the system
/// `PATH`, which never includes them. Every candidate must answer `--version`, so a broken symlink or a stray script
/// named `protoc` is skipped rather than reported as found.
public struct ProtocLocator: Sendable {
    public static let homebrewDirectory = "/opt/homebrew/bin"
    public static let usrLocalDirectory = "/usr/local/bin"
    /// Proves the include directory has the well-known types rather than unrelated headers.
    static let wellKnownTypeMarker = "google/protobuf/descriptor.proto"

    private let toolsDirectory: URL
    private let fileSystem: any ProtocFileSystem
    private let environment: [String: String]
    private let runner: any CommandRunning

    /// `toolsDirectory` is the app's `Tools` folder, which holds the managed install under `protoc/<version>`.
    public init(
        toolsDirectory: URL,
        fileSystem: any ProtocFileSystem = LocalProtocFileSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.toolsDirectory = toolsDirectory
        self.fileSystem = fileSystem
        self.environment = environment
        self.runner = runner
    }

    /// The first candidate that runs, or `nil` when no protoc is installed.
    ///
    /// Throws `ProtocLocatorError` when `overridePath` is set but is not a working protoc, rather than falling back:
    /// compiling with a protoc the user chose not to use would hide the broken setting. Throws `CancellationError`
    /// when the task is cancelled.
    @concurrent
    public func locate(overridePath: String?) async throws -> ProtocInstallation? {
        if let overridePath = overridePath.map({ ($0 as NSString).expandingTildeInPath }) {
            guard fileSystem.isExecutableFile(atPath: overridePath) else {
                throw ProtocLocatorError(path: overridePath, reason: "does not exist or is not executable")
            }
            guard let version = try await version(of: overridePath) else {
                throw ProtocLocatorError(path: overridePath, reason: "did not report a protoc version")
            }
            return installation(at: overridePath, source: .settingsOverride, version: version)
        }
        var tried = Set<String>()
        for (source, path) in candidates() where tried.insert(path).inserted {
            guard fileSystem.isExecutableFile(atPath: path), let version = try await version(of: path) else {
                continue
            }
            return installation(at: path, source: source, version: version)
        }
        return nil
    }

    /// The managed install's newest versions first, so one left by an older pin keeps working until replaced.
    private func candidates() -> [(ProtocSource, String)] {
        let managedRoot = ManagedProtocLayout.root(in: toolsDirectory)
        let versions = fileSystem.contentsOfDirectory(atPath: managedRoot.path)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let managed = versions.map { version in
            (ProtocSource.managed, ManagedProtocLayout.executable(in: managedRoot.appendingPathComponent(version)).path)
        }
        let path = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { (ProtocSource.path, "\($0)/protoc") }
        return managed + [
            (.homebrew, "\(Self.homebrewDirectory)/protoc"),
            (.usrLocal, "\(Self.usrLocalDirectory)/protoc")
        ] + path
    }

    /// `nil` when the candidate exits non-zero or prints something other than `libprotoc <version>`.
    private func version(of path: String) async throws -> String? {
        let result: CommandResult
        do {
            result = try await runner.run(URL(fileURLWithPath: path), arguments: ["--version"], currentDirectory: nil, timeout: .seconds(10))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard result.exitCode == 0 else {
            return nil
        }
        return Self.parseVersion(result.standardOutputText)
    }

    static func parseVersion(_ output: String) -> String? {
        let prefix = "libprotoc "
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix) else {
            return nil
        }
        let version = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    /// The managed install keeps its `include` beside `bin`; elsewhere `<prefix>/include`, checked both through the
    /// path as given and with symlinks resolved, since Homebrew links `bin/protoc` into its Cellar.
    private func installation(at path: String, source: ProtocSource, version: String) -> ProtocInstallation {
        let executable = URL(fileURLWithPath: path)
        let prefixes = [executable, URL(fileURLWithPath: fileSystem.resolvingSymlinks(inPath: path))]
            .map { $0.deletingLastPathComponent().deletingLastPathComponent() }
        let include = prefixes
            .map { $0.appendingPathComponent("include", isDirectory: true).standardizedFileURL }
            .first { fileSystem.fileExists(atPath: $0.appendingPathComponent(Self.wellKnownTypeMarker).path) }
        return ProtocInstallation(executable: executable, source: source, version: version, includeDirectory: include)
    }
}

/// Reqling's managed protoc lives at `<Tools>/protoc/<version>/{bin/protoc,include}`, the official archive's layout.
enum ManagedProtocLayout {
    static func root(in toolsDirectory: URL) -> URL {
        toolsDirectory.appendingPathComponent("protoc", isDirectory: true)
    }

    static func versionDirectory(_ version: String, in toolsDirectory: URL) -> URL {
        root(in: toolsDirectory).appendingPathComponent(version, isDirectory: true)
    }

    static func executable(in versionDirectory: URL) -> URL {
        versionDirectory.appendingPathComponent("bin/protoc")
    }

    static func includeDirectory(in versionDirectory: URL) -> URL {
        versionDirectory.appendingPathComponent("include", isDirectory: true)
    }
}
