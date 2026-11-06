import Foundation

/// The on-disk layout of a project folder:
///
///     <Name>.reqling/
///       project.json
///       project.pre.js, project.post.js          (scripts, when not empty)
///       environments/default.json   (always present)
///       environments/<slug>.json
///       requests/<folder-slug>/_folder.json
///       requests/<folder-slug>/_folder.pre.js     (and .post.js)
///       requests/**/<slug>.json
///       requests/**/<slug>.pre.js                 (and .post.js)
///
/// A script travels with the file it sits beside: renamed, moved, and trashed with it. Paths in `ProjectDiskIndex` are
/// relative to the project folder and use `/`.
enum ProjectLayout {
    static let projectFile = "project.json"
    static let environmentsDirectory = "environments"
    static let defaultEnvironmentSlug = "default"
    static let requestsDirectory = "requests"
    static let folderFile = "_folder.json"
    static let jsonExtension = "json"
    /// A scratch directory for two-phase renames; it only exists mid-sync.
    ///
    /// Items wait in `requests/` and `environments/` subfolders that mirror the project's own, so a save interrupted by a
    /// crash leaves entries the reader can still tell apart and recover.
    static let syncScratchDirectory = ".reqling-sync"
    static let scratchRequestsDirectory = "\(syncScratchDirectory)/\(requestsDirectory)"
    static let scratchEnvironmentsDirectory = "\(syncScratchDirectory)/\(environmentsDirectory)"

    static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : "\(parent)/\(name)"
    }

    static let scriptExtension = "js"

    /// The project's script file for `phase`, beside `project.json`.
    static func projectScriptPath(_ phase: ScriptPhase) -> String {
        "project.\(phase.fileSuffix).\(scriptExtension)"
    }

    /// A request's script file for `phase`: `list-users.pre.js` beside `list-users.json`.
    static func scriptPath(forRequestAt path: String, _ phase: ScriptPhase) -> String {
        let jsonSuffix = ".\(jsonExtension)"
        let stem = path.hasSuffix(jsonSuffix) ? String(path.dropLast(jsonSuffix.count)) : path
        return "\(stem).\(phase.fileSuffix).\(scriptExtension)"
    }

    /// A folder's script file for `phase`, inside it beside `_folder.json`.
    static func scriptPath(forFolderAt path: String, _ phase: ScriptPhase) -> String {
        join(path, folderScriptName(phase))
    }

    static func folderScriptName(_ phase: ScriptPhase) -> String {
        "_folder.\(phase.fileSuffix).\(scriptExtension)"
    }

    /// The slug and phase a request's script file name belongs to (`list-users.pre.js` → `list-users`, pre-request);
    /// `nil` for any other name.
    static func scriptOwner(ofFileNamed name: String) -> (slug: String, phase: ScriptPhase)? {
        for phase in ScriptPhase.allCases {
            let suffix = ".\(phase.fileSuffix).\(scriptExtension)"
            if name.hasSuffix(suffix), name.count > suffix.count {
                return (String(name.dropLast(suffix.count)), phase)
            }
        }
        return nil
    }
}

/// `project.json`.
struct ProjectFile: Codable, Equatable {
    var formatVersion: Int
    var id: ProjectID
    var name: String
    var environmentOrder: [EnvironmentID]
    /// Slugs of the top-level items, in display order.
    var rootOrder: [String]
    var auth: HTTPAuth
    var tls: ProjectTLSConfiguration
    var grpc: ProjectGRPCConfiguration

    init(
        formatVersion: Int,
        id: ProjectID,
        name: String,
        environmentOrder: [EnvironmentID],
        rootOrder: [String],
        auth: HTTPAuth,
        tls: ProjectTLSConfiguration,
        grpc: ProjectGRPCConfiguration
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.environmentOrder = environmentOrder
        self.rootOrder = rootOrder
        self.auth = auth
        self.tls = tls
        self.grpc = grpc
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        environmentOrder = try container.decodeIfPresent([EnvironmentID].self, forKey: .environmentOrder) ?? []
        rootOrder = try container.decodeIfPresent([String].self, forKey: .rootOrder) ?? []
        auth = try container.decodeIfPresent(HTTPAuth.self, forKey: .auth) ?? .none
        tls = try container.decodeIfPresent(ProjectTLSConfiguration.self, forKey: .tls) ?? ProjectTLSConfiguration()
        grpc = try container.decodeIfPresent(ProjectGRPCConfiguration.self, forKey: .grpc) ?? ProjectGRPCConfiguration()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(environmentOrder, forKey: .environmentOrder)
        try container.encode(rootOrder, forKey: .rootOrder)
        try container.encode(auth, forKey: .auth)
        if !tls.isEmpty {
            try container.encode(tls, forKey: .tls)
        }
        if !grpc.isEmpty || !grpc.protoFiles.isEmpty {
            try container.encode(grpc, forKey: .grpc)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case id
        case name
        case environmentOrder
        case rootOrder
        case auth
        case tls
        case grpc
    }
}

/// A folder's `_folder.json`.
struct FolderFile: Codable, Equatable {
    var id: RequestNodeID
    var name: String
    /// Slugs of the children, in display order.
    var order: [String]
    var auth: HTTPAuth
    var inheritScripts: Bool

    init(id: RequestNodeID, name: String, order: [String], auth: HTTPAuth, inheritScripts: Bool = true) {
        self.id = id
        self.name = name
        self.order = order
        self.auth = auth
        self.inheritScripts = inheritScripts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(RequestNodeID.self, forKey: .id) ?? RequestNodeID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        auth = try container.decodeIfPresent(HTTPAuth.self, forKey: .auth) ?? .inherit
        inheritScripts = try container.decodeIfPresent(Bool.self, forKey: .inheritScripts) ?? true
    }

    /// `inheritScripts` is written only when off, so folder files from before scripts stay byte for byte the same.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(order, forKey: .order)
        try container.encode(auth, forKey: .auth)
        if !inheritScripts {
            try container.encode(false, forKey: .inheritScripts)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case order
        case auth
        case inheritScripts
    }
}

/// Where each item of a loaded project lives on disk, and the bytes last read or written there.
struct ProjectDiskIndex: Equatable, Sendable {
    var nodePaths: [RequestNodeID: String] = [:]
    var environmentPaths: [EnvironmentID: String] = [:]
    /// Each file's content in Reqling's own encoding, as read. A save skips a file whose new encoding matches, so one
    /// edit rewrites one file even when the others were hand-formatted or carry keys this version ignores.
    var contents: [String: Data] = [:]
    /// Each file's bytes exactly as read or written. A save compares a file against them before overwriting it, so an
    /// external edit that the change monitor has not delivered yet aborts the save instead of being lost.
    var diskContents: [String: Data] = [:]
    /// Each directory's child order as its file states it (`rootOrder` for `requests`), so a save can keep unreadable
    /// entries' slugs where they were instead of rewriting the parent's file without them.
    var orders: [String: [String]] = [:]
    /// Entries the reader found but could not load (invalid JSON, unreadable files, foreign files). Layout never reuses
    /// their names, and the writer refuses to write over them or into them.
    var untrackedPaths: Set<String> = []
}

/// A problem found while loading a project that did not stop it from loading, such as one unreadable request file.
public struct ProjectLoadIssue: Hashable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public enum ProjectStorageError: Error, Equatable, LocalizedError {
    case notAProject(URL)
    case readOnly
    case projectNotFound
    case alreadyInLibrary
    case destinationExists(URL)
    /// A save would have written over, or into, an entry the reader could not load.
    case unreadableFileInTheWay(String)
    /// A file changed on disk after Reqling last read it; the save stopped so the change is not overwritten.
    case changedOnDisk(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject(let url):
            "“\(url.lastPathComponent)” is not a Reqling project; it has no \(ProjectLayout.projectFile)."
        case .readOnly:
            "This project was saved by a newer version of Reqling and is read-only."
        case .projectNotFound:
            "The project is no longer in the library."
        case .alreadyInLibrary:
            "That project is already in the library."
        case .destinationExists(let url):
            "“\(url.lastPathComponent)” already exists."
        case .unreadableFileInTheWay(let path):
            "Reqling could not read “\(path)”, so it will not save over it. Fix or remove that file, then try again."
        case .changedOnDisk(let path):
            "“\(path)” changed on disk since Reqling read it. The project was reloaded with that change; make your edit again."
        }
    }
}
