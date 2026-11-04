import ReqlingKit

/// One row of a body tree: a JSON value or XML node, or a bucket grouping a range of a large container's children.
///
/// `NSOutlineView` asks for every child of an item it expands and holds them by identity, so items are classes made
/// only when their parent first expands, and a container with more than `BodyTreeItem.bucketSize` children shows
/// buckets of them (`[0 … 99]`), nested again past that squared, rather than all of them.
@MainActor
final class BodyTreeItem {
    enum Node {
        case json(JSONEntry)
        case xml(Int)
        /// The document itself, never shown: its children are the top-level values, which bucket like any others
        /// (newline-delimited JSON can have thousands).
        case document
    }

    static let bucketSize = 100

    /// `nil` for a bucket.
    let node: Node?
    /// A node's position among its parent node's children, or the range of them a bucket groups.
    let range: Range<Int>
    /// The node this item is a child of, or, for a bucket, the node whose children it groups. Buckets in between don't
    /// count: paths and positions go node to node.
    private(set) weak var parentNode: BodyTreeItem?
    /// A node's children, loaded when it first expands.
    var childNodes: [Node]?
    /// The rows under this one: nodes, or buckets of them.
    var displayChildren: [BodyTreeItem]?

    init(node: Node?, range: Range<Int>, parentNode: BodyTreeItem?) {
        self.node = node
        self.range = range
        self.parentNode = parentNode
    }

    var isBucket: Bool {
        node == nil
    }

    /// The node whose child list this item's rows come from.
    var childSource: BodyTreeItem? {
        isBucket ? parentNode : self
    }

    /// The rows for `range` of `owner`'s children: the nodes themselves, or buckets of them when there are too many to
    /// list at once.
    static func level(of owner: BodyTreeItem, range: Range<Int>) -> [BodyTreeItem] {
        guard let nodes = owner.childNodes else {
            return []
        }
        guard range.count > bucketSize else {
            return range.map { BodyTreeItem(node: nodes[$0], range: $0..<$0 + 1, parentNode: owner) }
        }
        var size = bucketSize
        while (range.count + size - 1) / size > bucketSize {
            size *= bucketSize
        }
        return stride(from: range.lowerBound, to: range.upperBound, by: size).map {
            BodyTreeItem(node: nil, range: $0..<min($0 + size, range.upperBound), parentNode: owner)
        }
    }
}
