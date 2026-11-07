import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// The run sheet for a folder or project: which environment, how many iterations or which data file, what to do on a
/// failure, how long streams run, and which requests. Built inside the sheet's presenting body, so `init` reads nothing
/// observable; `load()`, from the sheet's `.task`, reads the project and the data file.
@MainActor
@Observable
final class BatchRunSetupModel {
    /// One request the run would run, as its checkbox row shows it.
    struct Row: Identifiable, Equatable {
        let id: RequestNodeID
        let name: String
        let kind: RequestKind
        /// The folder the request sits directly in, `nil` at the project's top level.
        let folderID: RequestNodeID?
        var isIncluded: Bool
    }

    /// Requests sitting directly in one folder, under its header; the scope's own requests have none. A folder whose
    /// requests a subfolder splits has a group either side of it.
    struct Group: Identifiable, Equatable {
        /// The group's first request, since a folder can have more than one group.
        let id: RequestNodeID
        let folderID: RequestNodeID?
        /// The folders from the scope down, as "Users / Admin"; `nil` for the scope's own requests.
        let title: String?
        let rows: [RequestNodeID]
    }

    /// What the chosen data file holds.
    enum DataState: Equatable {
        case none
        case reading
        case read(rows: Int, columns: [String])
        case failed(String)
    }

    let scope: BatchRunScope
    var environmentID: EnvironmentID?
    var iterations: BatchRunSettings.Iterations
    var count: Int
    var stopsOnFailure: Bool
    var streamSeconds: Double?
    var rows: [Row] = []
    private(set) var groups: [Group] = []
    private(set) var environments: [RequestEnvironment] = []
    private(set) var dataFile: URL?
    private(set) var data = DataState.none
    private(set) var isLoaded = false
    /// From Run until the run starts or doesn't, its trust question included, during which the sheet says nothing of
    /// the run it's starting being "another run".
    private(set) var isStarting = false

    @ObservationIgnored private unowned let app: AppModel

    init(scope: BatchRunScope, app: AppModel) {
        self.scope = scope
        self.app = app
        let settings = app.batchRunSettings(for: scope)
        environmentID = settings.environmentID
        iterations = settings.iterations
        count = settings.count
        stopsOnFailure = settings.stopsOnFailure
        streamSeconds = settings.streamSeconds
        dataFile = settings.dataFile
        excluded = settings.excluded
    }

    @ObservationIgnored private var excluded: Set<RequestNodeID>

    /// Reads the project's requests and environments, and the data file the last run used; once, so the sheet showing
    /// again never undoes what the person changed.
    func load() async {
        guard !isLoaded else {
            return
        }
        if let document = app.library.document(scope.projectID) {
            environments = document.allEnvironments
            environmentID = environmentID ?? app.activeEnvironmentID(for: scope.projectID)
            rows = document.requests(inFolder: scope.folderID).map { request in
                let folder = document.parentID(of: request.id)
                return Row(id: request.id, name: request.name, kind: request.kind, folderID: folder, isIncluded: !excluded.contains(request.id))
            }
            groups = Self.groups(of: rows, scope: scope, in: document)
        }
        isLoaded = true
        if let dataFile {
            await read(dataFile)
        }
    }

    /// Whether the folder or project is still there to run; the sheet stays open while it's deleted.
    var scopeExists: Bool {
        guard let document = app.library.document(scope.projectID) else {
            return false
        }
        return scope.folderID.map { document.folder($0) != nil } ?? true
    }

    var includedCount: Int {
        rows.count { $0.isIncluded }
    }

    var isRunEnabled: Bool {
        guard isLoaded, scopeExists, includedCount > 0, !isStarting, !app.batches.isRunning else {
            return false
        }
        if iterations == .dataFile, case .read = data {
            return true
        }
        return iterations == .count
    }

    /// What the footer says beside Run.
    var note: String? {
        if !scopeExists {
            return "This \(scope.folderID == nil ? "project" : "folder") no longer exists."
        }
        if app.batches.isRunning, !isStarting {
            return "Another run is going; stop it first."
        }
        guard isLoaded else {
            return nil
        }
        return "\(includedCount) of \(rows.count) request\(rows.count == 1 ? "" : "s")"
    }

    func chooseDataFile() async {
        guard let file = app.system.chooseFile(prompt: "Choose", message: "Choose a CSV or JSON file: one row per iteration.",
                                               allowedTypes: [.commaSeparatedText, .json]) else {
            return
        }
        dataFile = file
        iterations = .dataFile
        await read(file)
    }

    /// Starts the run; `true` once it has, which closes the sheet.
    func run() async -> Bool {
        isStarting = true
        defer { isStarting = false }
        let settings = BatchRunSettings(
            environmentID: environmentID,
            iterations: iterations,
            count: count,
            dataFile: dataFile,
            stopsOnFailure: stopsOnFailure,
            streamSeconds: streamSeconds,
            excluded: Set(rows.filter { !$0.isIncluded }.map(\.id))
        )
        return await app.beginBatchRun(scope, settings: settings)
    }

    private func read(_ file: URL) async {
        data = .reading
        do throws(IterationDataError) {
            let rows = try await IterationData.read(file)
            var seen: Set<String> = []
            let columns = rows.flatMap { $0.keys.sorted() }.filter { seen.insert($0).inserted }
            data = .read(rows: rows.count, columns: columns)
        } catch {
            data = .failed(error.message)
        }
    }

    /// The rows under their folders' headers, in sidebar order: a new group starts wherever the folder changes.
    private static func groups(of rows: [Row], scope: BatchRunScope, in document: ProjectDocument) -> [Group] {
        var groups: [Group] = []
        for row in rows {
            if let last = groups.last, last.folderID == row.folderID {
                groups[groups.count - 1] = Group(id: last.id, folderID: last.folderID, title: last.title, rows: last.rows + [row.id])
                continue
            }
            let title = title(of: row.folderID, scope: scope, in: document)
            groups.append(Group(id: row.id, folderID: row.folderID, title: title, rows: [row.id]))
        }
        return groups
    }

    private static func title(of folder: RequestNodeID?, scope: BatchRunScope, in document: ProjectDocument) -> String? {
        guard let folder, folder != scope.folderID else {
            return nil
        }
        var path = document.ancestors(of: folder) + [document.folder(folder)].compactMap(\.self)
        if let scopeFolder = scope.folderID, let index = path.firstIndex(where: { $0.id == scopeFolder }) {
            path.removeFirst(index + 1)
        }
        return path.map(\.name).joined(separator: " / ")
    }
}
