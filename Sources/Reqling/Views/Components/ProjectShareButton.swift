import ReqlingKit
import SwiftUI

/// Share… or Manage Sharing… for a project, as `AppModel.shareAction(for:)` has it; nothing for someone else's project
/// this person may not invite others to, or where sync can't run. The share sheet opens beside `origin`.
struct ProjectShareButton: View {
    let projectID: ProjectID
    let origin: ShareOrigin
    let model: AppModel

    var body: some View {
        switch model.shareAction(for: projectID) {
        case .manage?:
            Button("Manage Sharing…") { model.shareProject(projectID, from: origin) }
        case .share?, .unavailable?:
            // An unavailable one still says why when chosen.
            Button("Share…") { model.shareProject(projectID, from: origin) }
        case nil:
            EmptyView()
        }
    }
}
