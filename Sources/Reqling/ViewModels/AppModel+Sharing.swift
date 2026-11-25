import CloudKit
import ReqlingKit

/// Share…, Manage Sharing…, and a share someone opened, from the sidebar, the project's page, and the system.
extension AppModel {
    func shareAction(for id: ProjectID) -> ProjectShareAction? {
        iCloud.shareAction(for: id)
    }

    /// Share… or Manage Sharing…, chosen from `origin`. A project shared for the first time offers first to copy the
    /// Global variables it uses into its Default, since whoever it's shared with resolves them against their own Global.
    func shareProject(_ id: ProjectID, from origin: ShareOrigin) {
        switch iCloud.shareAction(for: id) {
        case .unavailable(let reason)?:
            alert = AppAlert(title: "Can't Share This Project", message: reason)
        case .share?:
            if library.globalVariablesOffer(for: id).isEmpty {
                presentShareSheet(for: id, from: origin)
            } else {
                sheet = .shareProject(id, from: origin)
            }
        case .manage?:
            presentShareSheet(for: id, from: origin)
        case nil:
            break
        }
    }

    /// Copies Global's `keys` into the project's Default, then shares it.
    func copyGlobalVariablesAndShare(_ id: ProjectID, keys: Set<String>, from origin: ShareOrigin) {
        guard perform("Couldn't Copy the Variables", { try library.copyGlobalVariables(keys, into: id) }) != nil else {
            return
        }
        presentShareSheet(for: id, from: origin)
    }

    /// The share sheet, beside `origin` while it's on screen.
    func presentShareSheet(for id: ProjectID, from origin: ShareOrigin) {
        Task {
            do {
                try await iCloud.presentShareSheet(for: id, anchor: shareAnchors.anchor(for: origin))
            } catch {
                alert = AppAlert(title: "Couldn't Share the Project", message: error.localizedDescription)
            }
        }
    }

    /// A share someone opened in Messages, Mail, or a browser: accepted, and once it's here, selected. With sync off, it
    /// waits for the person to turn sync on (`shareAwaitingSync`).
    func acceptShare(_ metadata: CKShare.Metadata) {
        Task {
            do {
                guard let accepted = try await iCloud.acceptShare(metadata) else {
                    return
                }
                if library.project(accepted.project) != nil {
                    selection = .project(accepted.project)
                } else if !iCloud.isOn {
                    shareAwaitingSync = accepted
                }
            } catch {
                alert = AppAlert(title: "Couldn't Open the Shared Project", message: error.localizedDescription)
            }
        }
    }

    /// Turns sync on for a share accepted while it was off, which arrives with its first sync.
    func turnOnSyncForAcceptedShare() {
        shareAwaitingSync = nil
        iCloud.setOn(true)
    }
}
