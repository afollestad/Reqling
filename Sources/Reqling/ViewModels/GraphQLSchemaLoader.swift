import Foundation
import Observation
import ReqlingKit

/// One GraphQL request's schema for its editor: what completion, checking, and the schema browser read, where it came
/// from, and why loading failed.
///
/// It loads only through `RequestRunner.graphQLSchema(for:in:refresh:options:)`, which reads the *saved* request, so
/// `prepare` (the editor's flush) runs before every load. A newer load supersedes one still in flight. Reloads also
/// follow what can change the schema while the request stays the same: the schema cache
/// (`GraphQLSchemaService.revision`), and the variables the request resolves against, which an environment switch
/// changes. Those reloads are quiet, keeping the shown status until their result lands, so a cache fill never flashes
/// the status row.
@MainActor
@Observable
final class GraphQLSchemaLoader {
    enum Status: Equatable {
        case loading
        /// Nothing can load yet; the text says what is missing.
        case idle(String)
        /// `issue` says why the schema may be stale or partial.
        case ready(GraphQLSchemaSnapshot.Source, typeCount: Int, issue: String?)
        case failed(String)
    }

    /// How long a URL, header, or schema source edit settles before the schema reloads, so typing a URL does not ask a
    /// server on every keystroke.
    static let reloadDelay: Duration = .milliseconds(500)

    private(set) var status: Status = .loading
    private(set) var snapshot: GraphQLSchemaSnapshot?
    /// Saves the editor's draft, so the load reads what the editor shows.
    @ObservationIgnored var prepare: (() -> Void)?
    /// Each load's result, whether a schema or none.
    @ObservationIgnored var onLoad: ((GraphQLSchemaSnapshot?) -> Void)?

    @ObservationIgnored private let projectID: ProjectID
    @ObservationIgnored private let requestID: RequestNodeID
    @ObservationIgnored private unowned let app: AppModel
    /// Bumped per load; a result from an older one is dropped even if it finished before seeing its cancellation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The cache revision and variables the last watch saw, so a save of the project that changes neither reloads
    /// nothing.
    @ObservationIgnored private var watched: Watched?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
    }

    /// Cancels a pending reload and a load in flight (an introspection), which would otherwise run on for an editor
    /// that is gone.
    isolated deinit {
        reloadTask?.cancel()
        loadTask?.cancel()
    }

    /// Loads now and starts following the cache and the project's variables.
    func start() {
        watch()
        load()
    }

    /// Starts following, and loads after `reloadDelay`: for a model created while the editor's spec is changing, where
    /// loading at once would save the draft from inside that change.
    func startAfterPause() {
        watch()
        scheduleReload()
    }

    /// Reloads after `reloadDelay`, restarting the pause on each call.
    func scheduleReload() {
        reloadTask?.cancel()
        let sleep = app.sleep
        reloadTask = Task { [weak self] in
            try? await sleep(Self.reloadDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            reloadTask = nil
            load()
        }
    }

    /// Waits out a pending reload and the load it starts, for tests: loading runs off the main actor, which counting
    /// main-actor turns cannot wait for.
    func settled() async {
        await reloadTask?.value
        await loadTask?.value
    }

    /// Asks the server again. A schema file needs no flag for that: every load rereads one whose size or modification
    /// date changed, so this rereads an edited file too.
    func refresh() {
        load(refresh: true)
    }

    func load(quietly: Bool = false, refresh: Bool = false) {
        reloadTask?.cancel()
        reloadTask = nil
        loadTask?.cancel()
        prepare?()
        generation += 1
        let generation = generation
        if let reason = idleReason() {
            apply(.idle(reason), snapshot: nil)
            return
        }
        if !quietly {
            status = .loading
        }
        let runner = app.runner
        let projectID = projectID
        let requestID = requestID
        loadTask = Task { [weak self] in
            let status: Status
            let snapshot: GraphQLSchemaSnapshot?
            do throws(RunFailure) {
                let loaded = try await runner.graphQLSchema(for: requestID, in: projectID, refresh: refresh)
                status = .ready(loaded.source, typeCount: loaded.typeSystem.browsableTypes.count, issue: loaded.issues.first)
                snapshot = loaded
            } catch {
                guard error.kind != .cancelled else {
                    return
                }
                status = .failed(error.message)
                snapshot = nil
            }
            guard let self, generation == self.generation else {
                return
            }
            apply(status, snapshot: snapshot)
        }
    }

    private func apply(_ status: Status, snapshot: GraphQLSchemaSnapshot?) {
        let changed = snapshot != self.snapshot
        self.snapshot = snapshot
        self.status = status
        if changed {
            onLoad?(snapshot)
        }
    }

    /// Introspection with no URL has nowhere to ask; a new request starts there, so it reads as a next step instead
    /// of an error.
    private func idleReason() -> String? {
        guard let spec = app.library.document(projectID)?.request(requestID)?.kind.httpSpec,
              case .introspection = spec.body.graphQL.schema,
              spec.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return "Enter the URL to read its schema by introspection, or choose a schema file."
    }

    /// Re-arms itself on each change, as `withObservationTracking` reports only the first. The project's variables are
    /// read through its document, which every save changes, so a change counts only when they or the cache did.
    private func watch() {
        let schemas = app.runner.graphQLSchemas
        if watched == nil {
            watched = Watched(revision: schemas?.revision ?? 0, tokens: app.tokenContext(for: projectID))
        }
        withObservationTracking {
            _ = schemas?.revision
            _ = app.tokenContext(for: projectID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.watchedDidChange()
            }
        }
    }

    private func watchedDidChange() {
        let now = Watched(revision: app.runner.graphQLSchemas?.revision ?? 0, tokens: app.tokenContext(for: projectID))
        let before = watched
        watched = now
        watch()
        if now.tokens != before?.tokens {
            scheduleReload()
        } else if now.revision != before?.revision {
            load(quietly: true)
        }
    }

    private struct Watched {
        let revision: Int
        let tokens: TemplateTokenContext
    }
}
