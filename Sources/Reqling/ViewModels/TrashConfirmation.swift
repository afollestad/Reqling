import ReqlingKit

/// An item awaiting confirmation before it moves to the Trash, with the name its confirmation shows; see
/// `AppModel.requestTrash(_:)`.
struct TrashConfirmation: Identifiable, Equatable {
    enum Kind {
        case project
        case folder
        case request
    }

    let item: SidebarItem
    let name: String
    let kind: Kind
    /// Whether the project syncs with iCloud, so the deletion reaches every other Mac that syncs it too.
    var syncs = false

    var id: SidebarItem {
        item
    }

    var title: String {
        "Move “\(name)” to the Trash?"
    }

    /// What Put Back restores and what it cannot: run history lives only on this Mac, outside the project's files. A
    /// synced item goes to the Trash on the other Macs too, where Put Back restores it as well; their Keychains keep its
    /// secret values.
    var consequences: String {
        let trash = syncs ? "the Trash on this Mac and your other Macs that sync it" : "the Trash"
        switch kind {
        case .project:
            return "Its folder goes to \(trash), where Finder can put it back. Its secret values are removed from this "
                + "Mac's Keychain, and its run history from this Mac."
        case .folder:
            return "It goes to \(trash) with everything inside, where Finder can put it back. The run history of its "
                + "requests is deleted from this Mac."
        case .request:
            return "It goes to \(trash), where Finder can put it back. Its run history is deleted from this Mac."
        }
    }
}
