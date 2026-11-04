import Foundation

/// The app being updated: where it runs from and what it is. Injected so tests stage against a fake bundle.
public struct AppUpdateTarget: Sendable {
    public static let appName = "Reqling.app"

    public let bundleURL: URL
    public let bundleIdentifier: String
    public let version: AppUpdateVersion?

    public init(bundleURL: URL, bundleIdentifier: String, version: AppUpdateVersion?) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    public static var running: AppUpdateTarget {
        AppUpdateTarget(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppUpdateVersion.init)
        )
    }

    /// Why an update can't replace the running app, or `nil` when it can: an app outside a bundle, one macOS
    /// translocated off a disk image, a development build, or a folder this user can't write to.
    func installLocationProblem(fileManager: FileManager = .default) -> String? {
        let url = bundleURL.standardizedFileURL
        guard url.pathExtension == "app" else {
            return "Reqling isn't running from an app bundle."
        }
        guard !url.path.contains("/AppTranslocation/") else {
            return "Move Reqling into Applications before installing updates."
        }
        guard !url.path.contains("/.build/"), !url.path.contains("/DerivedData/") else {
            return "Updates can't be installed over a development build."
        }
        guard fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            return "Reqling's folder isn't writable, so the update can't replace it."
        }
        return nil
    }
}

/// Where updates live under Application Support: staged metadata, staged bundles under `Staged/<tag>/Reqling.app`, and
/// helper scripts and logs.
struct AppUpdateStoragePaths: Sendable {
    let updatesDirectory: URL

    var metadataURL: URL {
        updatesDirectory.appendingPathComponent("staged-update.json")
    }

    var stagedRootURL: URL {
        updatesDirectory.appendingPathComponent("Staged", isDirectory: true)
    }

    func quarantinedMetadataURL(id: UUID) -> URL {
        updatesDirectory.appendingPathComponent("staged-update.installing-\(id.uuidString).json")
    }

    func stagedAppURL(tag: String) throws -> URL {
        let appURL = stagedRootURL
            .appendingPathComponent(tag.sanitizedForPathComponent, isDirectory: true)
            .appendingPathComponent(AppUpdateTarget.appName, isDirectory: true)
        _ = try validatedStagedDirectory(containing: appURL)
        return appURL
    }

    /// The single-child directory holding a staged app, after checking it sits exactly at `Staged/<name>/Reqling.app`
    /// with no symlink leading out. Cleanup deletes only what this returns, so tampered metadata can never aim a delete
    /// elsewhere.
    func validatedStagedDirectory(containing appURL: URL) throws -> URL {
        let root = stagedRootURL.standardizedFileURL
        let app = appURL.standardizedFileURL
        let directory = app.deletingLastPathComponent()
        let name = directory.lastPathComponent
        guard appURL.isFileURL,
              !appURL.pathComponents.contains("."), !appURL.pathComponents.contains(".."),
              app.lastPathComponent == AppUpdateTarget.appName,
              !name.isEmpty, name != ".", name != "..",
              directory.deletingLastPathComponent() == root else {
            throw AppUpdateFailure(message: "The staged app is outside Reqling's update storage.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let resolvedApp = app.resolvingSymlinksInPath()
        guard resolvedRoot.deletingLastPathComponent().path == updatesDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
              resolvedDirectory.deletingLastPathComponent().path == resolvedRoot.path,
              resolvedDirectory.lastPathComponent == name,
              resolvedApp.deletingLastPathComponent().path == resolvedDirectory.path,
              resolvedApp.lastPathComponent == AppUpdateTarget.appName else {
            throw AppUpdateFailure(message: "The staged app is outside Reqling's update storage.")
        }
        return directory
    }
}

extension String {
    /// Letters, digits, `.`, `-`, and `_`, with every other run replaced by `-`, so a tag can name a file safely.
    var sanitizedForPathComponent: String {
        components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
