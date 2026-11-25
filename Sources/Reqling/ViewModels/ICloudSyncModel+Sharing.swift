import AppKit
import CloudKit
import ReqlingKit

/// Sharing projects through iCloud: the system's share sheet over a project's zone-wide share, made when first shared,
/// and a share someone opened, accepted and synced in. Sync learns of each from its next fetch.
extension ICloudSyncModel {
    /// What a project's menus may offer about sharing it (`LibrarySync.shareAction(for:)`); `nil` where sync can't run.
    func shareAction(for id: ProjectID) -> ProjectShareAction? {
        shareService == nil ? nil : sync?.shareAction(for: id)
    }

    /// How a project is shared, for its sidebar badge: with this person, by whom, or by them, with how many; `nil` when
    /// it isn't.
    func sharingDescription(of project: LibraryProject) -> String? {
        if let sharing = project.sharing {
            let owner = sharing.ownerName.map { " by \($0)" } ?? ""
            return sharing.permission == .readOnly ? "Shared with you\(owner) to view" : "Shared with you\(owner)"
        }
        return sync?.sharedByYou[project.id].map { "Shared with \($0.reach)" }
    }

    /// Shows the share sheet for `id` beside `anchor`: its share made, titled with its name, once the person picks how to
    /// share it, or, shared already, the one it has, to manage. Someone who may only view it may invite others only to
    /// view it.
    func presentShareSheet(for id: ProjectID, anchor: SharingAnchor?) async throws {
        guard let shareService, let project = library.project(id), let action = shareAction(for: id) else {
            return
        }
        let provider = NSItemProvider()
        let container = shareService.container
        let readOnlyInvites: Bool
        switch action {
        case .share:
            readOnlyInvites = false
        case .manage(let readOnly):
            readOnlyInvites = readOnly
        case .unavailable:
            return
        }
        let options = Self.sharingOptions(readOnlyInvites: readOnlyInvites)
        if case .manage = action, let share = try await shareService.existingShare(of: id, sharing: project.sharing) {
            provider.registerCKShare(share, container: container, allowedSharingOptions: options)
        } else if project.sharing == nil {
            // Not shared yet, or no longer, as when it stopped on another Mac since this one last fetched.
            let name = project.name
            provider.registerCKShare(container: container, allowedSharingOptions: options) {
                try await shareService.prepareShare(of: id, title: name)
            }
        } else {
            throw CloudKitShareError.notFound
        }
        // What the sheet saves arrives as any change does, by push or as Reqling comes forward: macOS tells the sheet's
        // delegate nothing of a CloudKit share it saves or stops, only which way to share the person chose.
        system.showSharingPicker(provider, anchor: anchor)
    }

    /// Accepts a share someone opened, then syncs it in, when sync is on.
    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedShare? {
        guard let shareService else {
            return nil
        }
        let accepted = try await shareService.accept(metadata)
        if isOn {
            await sync?.syncNow()
        }
        return accepted
    }

    /// Every way to take part, and the choice of who may invite others, for the share sheet: the owner sets both for
    /// each person. Only viewing for anyone invited by someone who may only view.
    static func sharingOptions(readOnlyInvites: Bool) -> CKAllowedSharingOptions {
        let options = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: readOnlyInvites ? .readOnly : .any,
            allowedParticipantAccessOptions: .any
        )
        options.allowsParticipantsToInviteOthers = true
        return options
    }
}

extension ShareAudience {
    /// Who a project of this person's own reaches, as "Shared with …" ends.
    var reach: String {
        let invited = people == 1 ? "1 person" : "\(people) people"
        switch (people > 0, byLink) {
        case (true, true):
            return "\(invited) and anyone who has the link"
        case (true, false):
            return invited
        case (false, _):
            return "anyone who has the link"
        }
    }
}
