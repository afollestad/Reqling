import ReqlingKit

/// A folder or request awaiting confirmation before it moves into another project, with the names its confirmation
/// shows; see `AppModel.requestMove(_:from:to:into:at:)`.
struct MoveConfirmation: Identifiable, Equatable {
    /// Where the item goes: under `parent` (`nil` for the top level) of `destination`, at `index` in its children
    /// counted without the item, or last.
    struct Request: Equatable {
        let nodeID: RequestNodeID
        let source: ProjectID
        let destination: ProjectID
        let parent: RequestNodeID?
        let index: Int?
    }

    let request: Request
    let name: String
    let isFolder: Bool
    let sourceName: String
    let destinationName: String
    /// Whether the source project syncs with iCloud, so its old files go to the Trash on every other Mac that syncs it.
    var syncs = false

    var id: RequestNodeID {
        request.nodeID
    }

    var title: String {
        "Move “\(name)” to “\(destinationName)”?"
    }

    /// What the move rewrites, and what Put Back restores: the old files, while the item lives on in the destination.
    var consequences: String {
        let trash = syncs ? "the Trash on this Mac and your other Macs that sync “\(sourceName)”" : "the Trash"
        let moves = isFolder
            ? "Everything inside moves with it, and its requests keep their run history. Its old files in “\(sourceName)” go"
            : "It keeps its run history. Its old file in “\(sourceName)” goes"
        return "\(moves) to \(trash), where Finder can put \(isFolder ? "them" : "it") back. A file it uses from outside “\(destinationName)”'s "
            + "folder and repository is then found through a path kept on this Mac only."
    }
}
