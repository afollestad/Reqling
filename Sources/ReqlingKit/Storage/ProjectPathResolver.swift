import Foundation

/// Resolves `ProjectPathReference`s against a project folder and this Mac's recorded local paths.
public struct ProjectPathResolver: Sendable {
    public let projectRoot: URL
    public let localPaths: [LocalPathID: String]
    /// Shared paths outside the project's folder and repository that the person chose on this Mac
    /// (`WorkspaceStateStore.chosenOutsidePaths(in:)`), which resolve even though they lead out.
    public let chosenOutsidePaths: Set<String>
    /// The folder no repository at or above may widen a project's shared location to; see `sharesLocation`.
    let homeDirectory: URL

    public init(projectRoot: URL, localPaths: [LocalPathID: String] = [:], chosenOutsidePaths: Set<String> = []) {
        self.init(
            projectRoot: projectRoot,
            localPaths: localPaths,
            chosenOutsidePaths: chosenOutsidePaths,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    init(projectRoot: URL, localPaths: [LocalPathID: String], chosenOutsidePaths: Set<String> = [], homeDirectory: URL) {
        self.projectRoot = projectRoot
        self.localPaths = localPaths
        self.chosenOutsidePaths = chosenOutsidePaths
        self.homeDirectory = homeDirectory
    }

    /// `project`'s resolver, with this Mac's local paths and chosen outside paths from `workspace`.
    @MainActor
    public init(projectRoot: URL, workspace: WorkspaceStateStore, project: ProjectID) {
        self.init(
            projectRoot: projectRoot,
            localPaths: workspace.localPaths(in: project),
            chosenOutsidePaths: workspace.chosenOutsidePaths(in: project)
        )
    }

    /// The file's URL, or `nil` for a this-Mac-only reference recorded on another Mac, or a shared one that leads
    /// outside the project's folder and repository.
    ///
    /// Whoever shares the project wrote its relative paths, so a `../../.ssh/id_rsa` body, or a symlink in the folder
    /// that leads out, would have a request read and send a file the person never chose. One that leaves is treated as
    /// missing, unless the person chose it on this Mac (`chosenOutsidePaths`). A this-Mac-only path is the person's own
    /// choice, so it may point anywhere.
    public func url(for reference: ProjectPathReference) -> URL? {
        switch reference {
        case .relative(let path):
            let url = projectRoot.appendingPathComponent(path).standardizedFileURL
            return isAllowed(path, at: url) ? url : nil
        case .local(let id):
            return localPaths[id].map { URL(fileURLWithPath: $0) }
        }
    }

    /// A short description for errors and the UI.
    public func describe(_ reference: ProjectPathReference) -> String {
        switch reference {
        case .relative(let path):
            guard isAllowed(path, at: projectRoot.appendingPathComponent(path).standardizedFileURL) else {
                return "“\(path)” (outside the project’s folder and repository)"
            }
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

    private func isAllowed(_ path: String, at url: URL) -> Bool {
        chosenOutsidePaths.contains(path) || Self.sharesLocation(url, with: projectRoot, homeDirectory: homeDirectory)
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
    /// path keeps working for everyone who clones the project. Symlinks are resolved on both sides first, so a link
    /// inside the folder that leads out counts as outside.
    ///
    /// A repository at or above `homeDirectory` (a dotfiles repository in `~`) doesn't count, or every file in the
    /// home folder would share a location with every project outside a repository of its own.
    public static func sharesLocation(
        _ url: URL,
        with projectRoot: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let target = canonicalPath(of: url)
        let root = canonicalPath(of: projectRoot)
        let container = repositoryRoot(atOrAbove: root, below: canonicalPath(of: homeDirectory)) ?? root
        return target == container || target.hasPrefix(container + "/")
    }

    /// Whether `url` sits in a git repository, by the same rule `sharesLocation` widens a shared location with.
    static func isInsideRepository(_ url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        repositoryRoot(atOrAbove: canonicalPath(of: url), below: canonicalPath(of: homeDirectory)) != nil
    }

    /// The nearest folder at or above the resolved `start` holding `.git`, stopping short of the resolved `home` and its
    /// ancestors. Views describe file references on every render, so the walk starts from one resolved path, whose
    /// ancestors are real folders, rather than resolving each.
    private static func repositoryRoot(atOrAbove start: String, below home: String) -> String? {
        var candidate = URL(fileURLWithPath: start, isDirectory: true)
        while candidate.pathComponents.count > 1 {
            let path = candidate.path
            if path == home || home.hasPrefix(path + "/") {
                return nil
            }
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return path
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// `url`'s path with every symlink resolved. `resolvingSymlinksInPath` leaves a path that doesn't exist as it is,
    /// which would compare a missing file under `/var` against a resolved folder under `/private/var`; so the deepest
    /// part that exists is resolved, and the rest appended to it.
    static func canonicalPath(of url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while existing.pathComponents.count > 1, !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }
}
