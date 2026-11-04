import Foundation
import ReqlingKit

/// What MCP tools need from the window. Every other tool acts on the stores directly; these are the parts only the
/// window owns: its selection, its pending edits, and the protoc install whose progress it shows.
extension AppModel: MCPAppHost {
    func reveal(_ project: ProjectID, node: RequestNodeID?) {
        if let node {
            expandAncestors(of: node, in: project)
            selection = .node(project, node)
        } else {
            workspace.updateProject(project) { $0.isCollapsed = false }
            selection = .project(project)
        }
        isShowingSettings = false
        system.bringToFront()
    }

    var selectedItem: (project: ProjectID, node: RequestNodeID?)? {
        selection.map { ($0.projectID, $0.nodeID) }
    }

    func protocStatus() async -> MCPProtocStatus {
        await protocTooling.refresh()
        switch protocTooling.detection {
        case .found(let installation): return .found(installation)
        case .invalidOverride(let message): return .invalidOverride(message)
        case .missing, .unknown: return .missing
        }
    }

    func installProtoc() async throws -> ProtocInstallation {
        try await protocTooling.installAndWait()
    }
}
