import Foundation

/// Every request's runs on disk, one folder per request:
///
///     <directory>/<project>/outcomes.json          each request's latest outcome, for the sidebar's result filter
///     <directory>/<project>/<request>/runs.json    its runs, newest first, as `Entry`s
///     <directory>/<project>/<request>/<run>.json   one run's `RequestExchange`
///
/// Synchronous and unsynchronized: the app reaches it only through `RunHistoryWriter`, which serializes every call on
/// one queue. Tests and the screenshot mode seed it directly. A file that fails to decode reads as absent: the history
/// is what this Mac saw, never the only copy of anything.
public struct RunHistoryStore: Sendable {
    /// Each stored HTTP body, and all of a gRPC call's stored messages or an event stream's stored events together,
    /// are cut to this.
    public static let bodyLimit = 5 * 1024 * 1024
    /// Each stored gRPC message's JSON, and each stored event's data, is cut to this.
    public static let messageLimit = 64 * 1024

    /// A run as its request's index lists it.
    struct Entry: Hashable, Sendable, Codable {
        var summary: RunSummary
        /// The run file's size, which the size limit weighs.
        var storedByteCount: Int
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Stores a run the way a recorded one is, for tests and the screenshot mode; the app records through `RunHistory`.
    public func save(_ exchange: RequestExchange) {
        insert(exchange)
    }

    /// Writes the run, cut to the limits, as its request's newest; returns its entry, or `nil` when it could not be
    /// written. A failed write loses only the history: the run itself is unaffected.
    @discardableResult
    func insert(_ exchange: RequestExchange) -> Entry? {
        let folder = requestFolder(exchange.requestID, in: exchange.projectID)
        let url = runURL(exchange.id, in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Self.fitted(exchange))
            try data.write(to: url, options: .atomic)
            let entry = Entry(summary: RunSummary(exchange), storedByteCount: data.count)
            var entries = entries(for: exchange.requestID, in: exchange.projectID)
            entries.removeAll { $0.summary.id == exchange.id }
            entries.insert(entry, at: 0)
            try write(entries, to: folder)
            updateOutcome(of: exchange.requestID, in: exchange.projectID, to: entry.summary.outcomeKind)
            return entry
        } catch {
            // A run file its index never listed would take space nothing counts or removes.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// The request's runs, newest first.
    func entries(for request: RequestNodeID, in project: ProjectID) -> [Entry] {
        let url = requestFolder(request, in: project).appendingPathComponent(Self.indexName)
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// One run. Its IDs come from where it is stored, which a move between projects may have changed.
    func load(_ run: RunID, for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        let url = runURL(run, in: requestFolder(request, in: project))
        guard let data = try? Data(contentsOf: url), var exchange = try? JSONDecoder().decode(RequestExchange.self, from: data) else {
            return nil
        }
        exchange.projectID = project
        exchange.requestID = request
        return exchange
    }

    func latest(for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        entries(for: request, in: project).first.flatMap { load($0.summary.id, for: request, in: project) }
    }

    /// Every request's latest outcome in a project, from a small index kept beside the runs, so filtering by result
    /// never reads a request's runs.
    func outcomes(in project: ProjectID) -> [RequestNodeID: RunOutcomeKind] {
        Dictionary(uniqueKeysWithValues: outcomeIndex(in: project).compactMap { key, value in
            RequestNodeID(string: key).map { ($0, value) }
        })
    }

    /// Every request's entries, for pruning, which weighs runs across all projects.
    func allEntries() -> [RunKey: [Entry]] {
        var all: [RunKey: [Entry]] = [:]
        for projectFolder in subfolders(of: directory) {
            guard let project = ProjectID(string: projectFolder.lastPathComponent) else {
                continue
            }
            for requestFolder in subfolders(of: projectFolder) {
                guard let request = RequestNodeID(string: requestFolder.lastPathComponent) else {
                    continue
                }
                let entries = entries(for: request, in: project)
                if !entries.isEmpty {
                    all[RunKey(request, in: project)] = entries
                }
            }
        }
        return all
    }

    func remove(_ runs: Set<RunID>, for request: RequestNodeID, in project: ProjectID) {
        let folder = requestFolder(request, in: project)
        var entries = entries(for: request, in: project)
        entries.removeAll { runs.contains($0.summary.id) }
        guard let newest = entries.first else {
            removeAll(for: request, in: project)
            return
        }
        for run in runs {
            try? FileManager.default.removeItem(at: runURL(run, in: folder))
        }
        try? write(entries, to: folder)
        updateOutcome(of: request, in: project, to: newest.summary.outcomeKind)
    }

    func removeAll(for request: RequestNodeID, in project: ProjectID) {
        try? FileManager.default.removeItem(at: requestFolder(request, in: project))
        updateOutcome(of: request, in: project, to: nil)
    }

    func removeAll(in project: ProjectID) {
        try? FileManager.default.removeItem(at: projectFolder(project))
    }

    func removeEverything() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Carries requests' runs to another project, as when they move there with their IDs.
    func move(_ requests: [RequestNodeID], from source: ProjectID, to destination: ProjectID) {
        for request in requests {
            let origin = requestFolder(request, in: source)
            guard FileManager.default.fileExists(atPath: origin.path) else {
                continue
            }
            let target = requestFolder(request, in: destination)
            updateOutcome(of: request, in: source, to: nil)
            do {
                try FileManager.default.createDirectory(at: projectFolder(destination), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: origin, to: target)
            } catch {
                // Runs that cannot follow the request are dropped rather than left behind where nothing lists them.
                try? FileManager.default.removeItem(at: origin)
                continue
            }
            updateOutcome(of: request, in: destination, to: entries(for: request, in: destination).first?.summary.outcomeKind)
        }
    }

    /// The exchange cut to the limits, marked as cut when it was.
    private static func fitted(_ exchange: RequestExchange) -> RequestExchange {
        var stored = exchange
        switch exchange.outcome {
        case .response(var response) where response.eventStream != nil:
            if let fitted = response.eventStream?.fittingCache(dataLimit: messageLimit, totalLimit: bodyLimit), fitted.wasCut {
                response.eventStream = fitted.record
                stored.outcome = .response(response)
                stored.isBodyTruncated = true
            }
        case .response(var response) where response.body.count > bodyLimit:
            response.body = response.body.prefix(bodyLimit)
            stored.outcome = .response(response)
            stored.isBodyTruncated = true
        case .grpc(let call):
            let fitted = call.fittingCache(messageLimit: messageLimit, totalLimit: bodyLimit)
            if fitted.wasCut {
                stored.outcome = .grpc(fitted.record)
                stored.isBodyTruncated = true
            }
        default:
            break
        }
        return stored
    }

    private static let indexName = "runs.json"

    private func write(_ entries: [Entry], to folder: URL) throws {
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent(Self.indexName), options: .atomic)
    }

    private func outcomeIndex(in project: ProjectID) -> [String: RunOutcomeKind] {
        guard let data = try? Data(contentsOf: outcomesURL(for: project)) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: RunOutcomeKind].self, from: data)) ?? [:]
    }

    /// `nil` drops the request from the index.
    private func updateOutcome(of request: RequestNodeID, in project: ProjectID, to outcome: RunOutcomeKind?) {
        var index = outcomeIndex(in: project)
        guard index[request.description] != outcome else {
            return
        }
        index[request.description] = outcome
        try? FileManager.default.createDirectory(at: projectFolder(project), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: outcomesURL(for: project), options: .atomic)
    }

    private func subfolders(of url: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        return (contents ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func projectFolder(_ project: ProjectID) -> URL {
        directory.appendingPathComponent(project.description, isDirectory: true)
    }

    private func outcomesURL(for project: ProjectID) -> URL {
        projectFolder(project).appendingPathComponent("outcomes.json")
    }

    private func requestFolder(_ request: RequestNodeID, in project: ProjectID) -> URL {
        projectFolder(project).appendingPathComponent(request.description, isDirectory: true)
    }

    private func runURL(_ run: RunID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(run).json")
    }
}
