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
    /// How the project is shared, which changes what trashing it does.
    var sharing: Sharing?

    enum Sharing: Equatable {
        /// Someone else's: trashing it leaves the share, and it stays with everyone else.
        case withYou
        /// This person's own, shared with others: trashing it removes it for them too.
        case byYou(ShareAudience)
    }

    var id: SidebarItem {
        item
    }

    var title: String {
        sharing == .withYou ? "Leave “\(name)”?" : "Move “\(name)” to the Trash?"
    }

    var actionTitle: String {
        sharing == .withYou ? "Leave" : "Move to Trash"
    }

    /// What Put Back restores and what it cannot: run history lives only on this Mac, outside the project's files. A
    /// synced item goes to the Trash on the other Macs too, where Put Back restores it as well; their Keychains keep its
    /// secret values.
    var consequences: String {
        let trash = syncs ? "the Trash on this Mac and your other Macs that sync it" : "the Trash"
        switch (kind, sharing) {
        case (.project, .withYou?):
            return "You stop getting its changes, and your copy goes to \(trash). It stays with its owner and everyone "
                + "else it's shared with. Your secret values for it are removed from this Mac's Keychain and from iCloud."
        case (.project, .byYou(let audience)?):
            return "It's shared with \(audience.reach), so it's deleted for them too, and their copies go to the Trash. "
                + "Yours goes to \(trash), where Finder can put it back."
        case (.project, nil):
            return "Its folder goes to \(trash), where Finder can put it back. Its secret values are removed from this "
                + "Mac's Keychain, and its run history from this Mac."
        case (.folder, _):
            return "It goes to \(trash) with everything inside, where Finder can put it back. The run history of its "
                + "requests is deleted from this Mac."
        case (.request, _):
            return "It goes to \(trash), where Finder can put it back. Its run history is deleted from this Mac."
        }
    }
}
