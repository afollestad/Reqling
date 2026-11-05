import Foundation
import Security
import ReqlingKit

/// A library over a temporary directory, an in-memory secret store, and a directory "Trash", with watching off.
@MainActor
struct LibraryFixture {
    let directory: TemporaryDirectory
    let secrets = InMemorySecretStore()
    let trash: FailableTrash
    let library: ProjectLibrary

    init() throws {
        directory = try TemporaryDirectory()
        trash = FailableTrash(wrapping: DirectoryTrash(directory: directory.file("Trash")))
        library = Self.makeLibrary(in: directory, secrets: secrets, trash: trash)
    }

    /// A second library over the same storage, as a relaunch would build.
    func relaunched(secretStore: (any SecretStore)? = nil) -> ProjectLibrary {
        Self.makeLibrary(in: directory, secrets: secretStore ?? secrets, trash: trash)
    }

    var registryURL: URL {
        directory.file("Support/library.json")
    }

    var globalEnvironmentURL: URL {
        directory.file("Support/global-environment.json")
    }

    var trashDirectory: URL {
        directory.file("Trash")
    }

    func trashedNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path)) ?? []).map { name in
            // `DirectoryTrash` prefixes a UUID and a dash.
            String(name.dropFirst(37))
        }.sorted()
    }

    func projectURL(_ id: ProjectID) -> URL {
        library.project(id)!.url
    }

    func exists(_ relativePath: String, in project: ProjectID) -> Bool {
        FileManager.default.fileExists(atPath: projectURL(project).appendingPathComponent(relativePath).path)
    }

    func contents(_ relativePath: String, in project: ProjectID) throws -> String {
        try String(contentsOf: projectURL(project).appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Writes as another tool would, creating intermediate folders; the library notices only on `reload`.
    func write(_ text: String, to relativePath: String, in project: ProjectID) throws {
        let url = projectURL(project).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func move(_ relativePath: String, to destination: String, in project: ProjectID) throws {
        let target = projectURL(project).appendingPathComponent(destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: projectURL(project).appendingPathComponent(relativePath), to: target)
    }

    private static func makeLibrary(in directory: TemporaryDirectory, secrets: any SecretStore, trash: FailableTrash) -> ProjectLibrary {
        ProjectLibrary(configuration: .init(
            registryURL: directory.file("Support/library.json"),
            defaultProjectsDirectory: directory.file("Projects"),
            globalEnvironmentURL: directory.file("Support/global-environment.json"),
            secretStore: secrets,
            trasher: trash,
            monitorFactory: nil
        ))
    }
}

/// Refuses every trash while `isFailing`, as a volume without a Trash does.
final class FailableTrash: FileTrashing, @unchecked Sendable {
    private let wrapped: any FileTrashing
    var isFailing = false

    init(wrapping wrapped: any FileTrashing) {
        self.wrapped = wrapped
    }

    func trash(_ url: URL) throws {
        if isFailing {
            throw CocoaError(.featureUnsupported)
        }
        try wrapped.trash(url)
    }
}

extension RequestItem {
    static func http(_ name: String, method: HTTPMethod = .get, url: String = "https://example.com") -> RequestItem {
        RequestItem(name: name, kind: .http(HTTPRequestSpec(method: method, url: url)))
    }
}

/// Fails every read while `isLocked`, as a denied Keychain prompt does.
final class LockableSecretStore: SecretStore, @unchecked Sendable {
    private let wrapped: any SecretStore
    var isLocked = true

    init(wrapping wrapped: any SecretStore) {
        self.wrapped = wrapped
    }

    func secrets(for account: SecretAccount) throws -> [String: String] {
        if isLocked {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
        return try wrapped.secrets(for: account)
    }

    func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws {
        try wrapped.setSecrets(secrets, for: account)
    }
}
