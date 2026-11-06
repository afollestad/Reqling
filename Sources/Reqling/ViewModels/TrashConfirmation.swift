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

    var id: SidebarItem {
        item
    }

    var title: String {
        "Move “\(name)” to the Trash?"
    }

    /// What Put Back restores and what it cannot: run history lives only on this Mac, outside the project's files.
    var consequences: String {
        switch kind {
        case .project:
            "Its folder goes to the Trash, where Finder can put it back. Its secret values are removed from your Keychain, "
                + "and its run history from this Mac."
        case .folder:
            "It goes to the Trash with everything inside, where Finder can put it back. The run history of its requests is "
                + "deleted from this Mac."
        case .request:
            "It goes to the Trash, where Finder can put it back. Its run history is deleted from this Mac."
        }
    }
}
