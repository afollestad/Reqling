import Foundation
import Observation
import ReqlingKit

/// One gRPC request's schema for its editor: the services and methods its pickers offer, where they came from, and
/// why loading failed.
///
/// It loads only through `RequestRunner.grpcSchema(for:in:options:)`, which reads the *saved* request, so `prepare`
/// (the editor's flush) runs before every load. A newer load supersedes one still in flight. Reloads also follow what
/// can change a schema while the request stays the same: the reflection cache (`GRPCSchemaService.revision`) and the
/// project's proto workspace. Those reloads are quiet, keeping the shown status until their result lands, so a
/// recompile or a cache fill never flashes the status row.
@MainActor
@Observable
final class GRPCSchemaLoader {
    enum Status: Equatable {
        case loading
        /// Nothing can load yet; the text says what is missing.
        case idle(String)
        /// `issue` says why part of the schema may be missing.
        case ready(GRPCSchema.Source, issue: String?)
        case failed(String)
    }

    /// How long a target, security, or schema source edit settles before the schema reloads, so typing a target
    /// does not ask a server for every keystroke.
    static let reloadDelay: Duration = .milliseconds(500)

    private(set) var status: Status = .loading
    /// The last load's services, sorted by full name; empty after a failed load.
    private(set) var services: [GRPCServiceDescriptor] = []
    /// The last load's registry, for Example messages. Read `services` first where a view should follow reloads.
    @ObservationIgnored private(set) var registry: DescriptorRegistry = .empty
    /// Saves the editor's draft, so the load reads what the editor shows.
    @ObservationIgnored var prepare: (() -> Void)?

    @ObservationIgnored private let projectID: ProjectID
    @ObservationIgnored private let requestID: RequestNodeID
    @ObservationIgnored private unowned let app: AppModel
    /// Bumped per load; a result from an older one is dropped even if it finished before seeing its cancellation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
    }

    /// Cancels a pending reload and a load in flight (a reflection call, waiting out a compile), which would otherwise
    /// run on for an editor that is gone.
    isolated deinit {
        reloadTask?.cancel()
        loadTask?.cancel()
    }

    /// Loads now and starts following the reflection cache and the project's protos.
    func start() {
        watch()
        load()
    }

    /// The method at `service/method`, if the loaded schema has it.
    func method(service: String, name: String) -> GRPCMethodDescriptor? {
        services.first { $0.fullName == service }?.methods.first { $0.name == name }
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

    /// Asks the server again on the next lookup, then reloads; project protos and descriptor sets already follow
    /// their files.
    func refresh() {
        app.grpcSchemas?.refreshReflection(in: projectID)
        load()
    }

    func load(quietly: Bool = false) {
        reloadTask?.cancel()
        reloadTask = nil
        loadTask?.cancel()
        prepare?()
        generation += 1
        let generation = generation
        if let reason = idleReason() {
            apply(.idle(reason), registry: .empty)
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
            let registry: DescriptorRegistry
            do {
                let schema = try await runner.grpcSchema(for: requestID, in: projectID)
                status = .ready(schema.source, issue: schema.issue)
                registry = schema.registry
            } catch {
                status = .failed(error.message)
                registry = .empty
            }
            guard let self, generation == self.generation else {
                return
            }
            apply(status, registry: registry)
        }
    }

    private func apply(_ status: Status, registry: DescriptorRegistry) {
        self.registry = registry
        services = registry.services
        self.status = status
    }

    /// Reflection with no target has nowhere to ask, and the runner would fail it as an invalid target; a new request
    /// starts there, so it reads as a next step instead of an error.
    private func idleReason() -> String? {
        guard let document = app.library.document(projectID), let spec = document.request(requestID)?.kind.grpcSpec else {
            return nil
        }
        let usesReflection = spec.schema == .reflection || (spec.schema == .automatic && document.grpc.isEmpty)
        guard usesReflection, spec.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return "Enter a target to read its schema through server reflection, or configure the project's protos."
    }

    /// Re-arms itself on each change, as `withObservationTracking` reports only the first.
    private func watch() {
        let schemas = app.grpcSchemas
        let workspaces = app.protoWorkspaces
        let projectID = projectID
        withObservationTracking {
            _ = schemas?.revision
            _ = workspaces.workspace(for: projectID)?.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.watch()
                self?.load(quietly: true)
            }
        }
    }
}
