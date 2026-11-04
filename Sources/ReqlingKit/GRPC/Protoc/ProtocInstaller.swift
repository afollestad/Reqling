import Foundation

/// One official protoc release: the archive Reqling downloads and the digest it must match.
public struct ProtocRelease: Hashable, Sendable {
    public let version: String
    public let archiveURL: URL
    /// Lowercase hex SHA-256 of the archive, recorded from a download made when the pin was chosen. It is what makes
    /// the download trustworthy; never fetch it from the network at install time.
    public let sha256: String

    public init(version: String, archiveURL: URL, sha256: String) {
        self.version = version
        self.archiveURL = archiveURL
        self.sha256 = sha256
    }

    /// protobuf v36.2 (released 2026-09-17), the latest stable release when pinned. Bump all three fields together,
    /// with the digest computed from a fresh download of the universal macOS archive.
    public static let pinned = ProtocRelease(
        version: "36.2",
        archiveURL: releaseURL("https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protoc-36.2-osx-universal_binary.zip"),
        sha256: "83d0dc80672f53486f54299bca6177159f9cad1fd54d4d3143eeea53c4423e1b"
    )

    private static func releaseURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid protoc release URL: \(string)")
        }
        return url
    }
}

/// What `ProtocInstaller.install` is doing, for a progress display.
public enum ProtocInstallPhase: Hashable, Sendable {
    case downloading(receivedBytes: Int64, expectedBytes: Int64?)
    case verifying
    case extracting
}

public enum ProtocInstallError: Error, Hashable, Sendable, LocalizedError {
    case httpStatus(Int)
    case writeFailed(String)
    case digestMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case versionMismatch(expected: String, actual: String?)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            "The protoc download failed with HTTP status \(status)."
        case .writeFailed(let path):
            "Could not write \(path)."
        case .digestMismatch:
            "The downloaded protoc did not match its expected checksum, so it was discarded."
        case .extractionFailed(let reason):
            "Could not unpack protoc: \(reason)"
        case .versionMismatch(let expected, let actual):
            "The downloaded protoc reported version \(actual ?? "nothing") instead of \(expected)."
        }
    }
}

/// Installs the pinned protoc release into `<Tools>/protoc/<version>/`.
///
/// Everything happens in a staging folder beside the destination, removed on every exit: the archive is verified
/// against `ProtocRelease.sha256` before anything is unpacked, and the unpacked tree must report the pinned version
/// before one rename moves it into place. A failed or cancelled install therefore never leaves a partial tree that
/// `ProtocLocator` would pick up.
public struct ProtocInstaller: Sendable {
    static let dittoURL = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let stagingPrefix = ".staging-"

    private let toolsDirectory: URL
    private let release: ProtocRelease
    private let downloader: ProtocDownloader
    private let runner: any CommandRunning

    /// `toolsDirectory` is the app's `Tools` folder under its Application Support directory.
    public init(
        toolsDirectory: URL,
        release: ProtocRelease = .pinned,
        downloader: ProtocDownloader = ProtocDownloader(),
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.toolsDirectory = toolsDirectory
        self.release = release
        self.downloader = downloader
        self.runner = runner
    }

    /// Where this release lives once installed.
    public var installDirectory: URL {
        ManagedProtocLayout.versionDirectory(release.version, in: toolsDirectory)
    }

    /// Downloads, verifies, and installs the release, then removes every other managed version.
    ///
    /// Throws `ProtocInstallError`, a `URLError` for transport failures, or `CancellationError`.
    @concurrent
    public func install(progress: @escaping @Sendable (ProtocInstallPhase) -> Void = { _ in }) async throws -> ProtocInstallation {
        let root = ManagedProtocLayout.root(in: toolsDirectory)
        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(release.archiveURL.lastPathComponent)
        let digest = try await downloader.download(release.archiveURL, to: archive) { received, expected in
            progress(.downloading(receivedBytes: received, expectedBytes: expected))
        }
        progress(.verifying)
        guard digest == release.sha256.lowercased() else {
            throw ProtocInstallError.digestMismatch(expected: release.sha256, actual: digest)
        }

        progress(.extracting)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await extract(archive, to: unpacked)
        try await verifyVersion(of: ManagedProtocLayout.executable(in: unpacked))
        try moveIntoPlace(unpacked, staging: staging)
        removeStaleVersions(in: root, keeping: staging)

        let include = ManagedProtocLayout.includeDirectory(in: installDirectory)
        let hasInclude = FileManager.default.fileExists(atPath: include.appendingPathComponent(ProtocLocator.wellKnownTypeMarker).path)
        return ProtocInstallation(
            executable: ManagedProtocLayout.executable(in: installDirectory),
            source: .managed,
            version: release.version,
            includeDirectory: hasInclude ? include : nil
        )
    }

    private func extract(_ archive: URL, to destination: URL) async throws {
        let result: CommandResult
        do {
            result = try await runner.run(
                Self.dittoURL,
                arguments: ["-x", "-k", archive.path, destination.path],
                currentDirectory: nil,
                timeout: .seconds(120)
            )
        } catch let error as CommandError {
            throw ProtocInstallError.extractionFailed(error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let reason = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProtocInstallError.extractionFailed(reason.isEmpty ? "ditto exited with status \(result.exitCode)." : reason)
        }
    }

    private func verifyVersion(of executable: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProtocInstallError.extractionFailed("The archive has no bin/protoc.")
        }
        let result: CommandResult
        do {
            result = try await runner.run(executable, arguments: ["--version"], currentDirectory: nil, timeout: .seconds(10))
        } catch let error as CommandError {
            throw ProtocInstallError.extractionFailed(error.localizedDescription)
        }
        let version = result.exitCode == 0 ? ProtocLocator.parseVersion(result.standardOutputText) : nil
        guard version == release.version else {
            throw ProtocInstallError.versionMismatch(expected: release.version, actual: version)
        }
    }

    /// One rename when nothing is installed yet. A reinstall first renames the old tree into staging, where the
    /// cleanup removes it, leaving only a brief window with no install rather than a mix of both.
    private func moveIntoPlace(_ unpacked: URL, staging: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.moveItem(at: installDirectory, to: staging.appendingPathComponent("previous", isDirectory: true))
        }
        try fileManager.moveItem(at: unpacked, to: installDirectory)
    }

    /// Other versions, and staging left by an install that crashed; each is a full protoc and include tree.
    private func removeStaleVersions(in root: URL, keeping staging: URL) {
        let keep: Set<String> = [release.version, staging.lastPathComponent]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries where !keep.contains(entry) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }
    }
}
