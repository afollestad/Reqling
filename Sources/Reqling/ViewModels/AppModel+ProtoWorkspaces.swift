import Foundation
import ReqlingKit

extension AppModel {
    /// Gives every loaded project with proto definitions a workspace on its current configuration and local paths,
    /// and drops the rest. Cheap enough for every library change: a workspace recompiles only when its configuration
    /// resolves to different paths.
    ///
    /// A project that is listed but did not load (moved, mid-checkout) keeps the workspace it has, so its schema
    /// survives until the project loads again; one that left the library or cleared its protos loses it.
    func syncProtoWorkspaces() {
        var keep = Set<ProjectID>()
        for project in library.projects {
            guard let document = project.document else {
                if protoWorkspaces.workspace(for: project.id) != nil {
                    keep.insert(project.id)
                }
                continue
            }
            guard !document.grpc.isEmpty, let resolver = pathResolver(for: project.id) else {
                continue
            }
            protoWorkspaces.workspace(for: project.id, configuration: document.grpc, resolver: resolver)
            keep.insert(project.id)
        }
        protoWorkspaces.retain(only: keep)
    }
}
