import Foundation

/// Resolves `ProjectPathReference`s against a project folder and this Mac's recorded local paths.
public struct ProjectPathResolver: Sendable {
    public let projectRoot: URL
    public let localPaths: [LocalPathID: String]

    public init(projectRoot: URL, localPaths: [LocalPathID: String] = [:]) {
        self.projectRoot = projectRoot
        self.localPaths = localPaths
    }

    /// The file's URL, or `nil` for a this-Mac-only reference recorded on another Mac.
    public func url(for reference: ProjectPathReference) -> URL? {
        switch reference {
        case .relative(let path):
            return projectRoot.appendingPathComponent(path).standardizedFileURL
        case .local(let id):
            return localPaths[id].map { URL(fileURLWithPath: $0) }
        }
    }

    /// A short description for errors and the UI.
    public func describe(_ reference: ProjectPathReference) -> String {
        switch reference {
        case .relative(let path):
            return "“\(path)”"
        case .local(let id):
            return localPaths[id].map { "“\(($0 as NSString).lastPathComponent)”" } ?? "A file chosen on another Mac"
        }
    }

    /// Reads the referenced file, failing with a description of what is missing.
    public func data(for reference: ProjectPathReference) throws(TLSError) -> Data {
        guard let url = url(for: reference), let data = try? Data(contentsOf: url) else {
            throw .missingFile(describe(reference))
        }
        return data
    }

    /// `target` relative to `root`, using `..` segments where needed (`../proto/api.proto`).
    public static func relativePath(from root: URL, to target: URL) -> String {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let targetComponents = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < rootComponents.count, common < targetComponents.count, rootComponents[common] == targetComponents[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: rootComponents.count - common)
        let path = (ups + targetComponents[common...]).joined(separator: "/")
        return path.isEmpty ? "." : path
    }

    /// Whether `url` lives inside the project folder or the git repository containing it, the places a relative
    /// path keeps working for everyone who clones the project.
    public static func sharesLocation(_ url: URL, with projectRoot: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let container = repositoryRoot(containing: projectRoot) ?? projectRoot
        let containerPath = container.standardizedFileURL.resolvingSymlinksInPath().path
        return target == containerPath || target.hasPrefix(containerPath + "/")
    }

    private static func repositoryRoot(containing url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
