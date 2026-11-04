import Foundation
import Observation

/// Every open project's `ProtoWorkspace`, created on first use and stopped when its project is forgotten.
@MainActor
@Observable
public final class ProtoWorkspaceStore {
    public private(set) var workspaces: [ProjectID: ProtoWorkspace] = [:]
    @ObservationIgnored private let environment: ProtoWorkspaceEnvironment

    public init(environment: ProtoWorkspaceEnvironment) {
        self.environment = environment
    }

    /// The project's workspace, created and compiling on first use. An existing one adopts `configuration` and
    /// `resolver`, recompiling only when they resolve to different paths, so callers can pass them on every change.
    @discardableResult
    public func workspace(for projectID: ProjectID, configuration: ProjectGRPCConfiguration, resolver: ProjectPathResolver) -> ProtoWorkspace {
        if let workspace = workspaces[projectID] {
            workspace.update(configuration: configuration, resolver: resolver)
            return workspace
        }
        let workspace = ProtoWorkspace(projectID: projectID, configuration: configuration, resolver: resolver, environment: environment)
        workspaces[projectID] = workspace
        return workspace
    }

    public func workspace(for projectID: ProjectID) -> ProtoWorkspace? {
        workspaces[projectID]
    }

    /// Stops and drops every workspace whose project is not in `projectIDs`, such as after the library forgets one.
    public func retain(only projectIDs: Set<ProjectID>) {
        for id in workspaces.keys where !projectIDs.contains(id) {
            forget(id)
        }
    }

    public func forget(_ projectID: ProjectID) {
        workspaces.removeValue(forKey: projectID)?.stop()
    }

    /// Recompiles every workspace past the compile cache, for changes no file event reports: protoc installed or the
    /// Settings override edited.
    public func recompileAll() {
        for workspace in workspaces.values {
            workspace.recompile()
        }
    }
}
