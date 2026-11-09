import ReqlingKit

/// The sidebar's rows as a drag sees them, in the order they show, with the dragged item and everything inside it left
/// out. Leaving them out is what makes every row's `index` count without the dragged item, as `ProjectDocument.moveNode`
/// and `ProjectLibrary.moveProject` take it, so a drop resolves to an index with no adjustment, within a project or
/// across. Rebuilt for every targeting pass, since a folder or project opened mid-drag adds rows.
struct SidebarDragLayout: Equatable {
    /// One project as the sidebar lists it, which is all the layout reads. Dragging is off while the sidebar is filtered,
    /// so `items` is the whole tree and the shown order is the saved one.
    struct Project {
        let id: ProjectID
        /// Loaded and writable: it takes folders and requests dropped into it, and gives up its own.
        let acceptsNodes: Bool
        let isExpanded: Bool
        let items: [RequestNode]
    }

    enum RowKind: Equatable {
        case project(isExpanded: Bool)
        /// `hasVisibleChildren` counts only rows other than the dragged one.
        case folder(isExpanded: Bool, hasVisibleChildren: Bool)
        case request
    }

    struct Row: Equatable {
        let item: SidebarItem
        let kind: RowKind
        /// The folders between the row and its project: 0 at the top level, and -1 for the project itself.
        let depth: Int
        /// The folder holding the row; `nil` at a project's top level and for a project.
        let parent: RequestNodeID?
        /// Its place among its parent's children, or a project's among the projects, counted without the dragged item.
        let index: Int
        /// Whether the row's project takes dropped folders and requests.
        let acceptsNodes: Bool
    }

    /// Where the dragged item sits now, counted as `Row.index` is; a drop there would change nothing.
    enum Origin: Equatable {
        case project(index: Int)
        case node(ProjectID, parent: RequestNodeID?, index: Int)
    }

    let source: SidebarItem
    let rows: [Row]
    let origin: Origin
    /// The dragged node and everything inside it; empty when a project is dragged.
    let sourceNodes: Set<RequestNodeID>

    /// Whether `item` is the dragged item or inside it, the rows that fade and take no drop.
    func isDragged(_ item: SidebarItem) -> Bool {
        Self.isDragged(item, source: source, sourceNodes: sourceNodes)
    }

    static func isDragged(_ item: SidebarItem, source: SidebarItem, sourceNodes: Set<RequestNodeID>) -> Bool {
        switch source {
        case .project(let project):
            item.projectID == project
        case .node(let project, _):
            item.projectID == project && item.nodeID.map(sourceNodes.contains) == true
        }
    }

    /// `nil` when `source` is gone, or is a folder or request in a project that can't give it up.
    static func make(
        source: SidebarItem,
        projects: [Project],
        isFolderExpanded: @escaping (ProjectID, RequestNodeID) -> Bool
    ) -> SidebarDragLayout? {
        var builder = Builder(source: source, isFolderExpanded: isFolderExpanded)
        var projectIndex = 0
        for project in projects {
            if source == .project(project.id) {
                builder.origin = .project(index: projectIndex)
                continue
            }
            if source.projectID == project.id, !project.acceptsNodes {
                return nil
            }
            builder.rows.append(Row(
                item: .project(project.id),
                kind: .project(isExpanded: project.isExpanded),
                depth: -1,
                parent: nil,
                index: projectIndex,
                acceptsNodes: project.acceptsNodes
            ))
            projectIndex += 1
            builder.add(project.items, of: project, parent: nil, depth: 0, isShown: project.isExpanded)
        }
        guard let origin = builder.origin else {
            return nil
        }
        return SidebarDragLayout(source: source, rows: builder.rows, origin: origin, sourceNodes: builder.sourceNodes)
    }
}

private struct Builder {
    let source: SidebarItem
    let isFolderExpanded: (ProjectID, RequestNodeID) -> Bool
    var rows: [SidebarDragLayout.Row] = []
    var origin: SidebarDragLayout.Origin?
    var sourceNodes: Set<RequestNodeID> = []

    /// Walks hidden rows too, without listing them, since the dragged item can sit anywhere the walk has to find it.
    mutating func add(_ children: [RequestNode], of project: SidebarDragLayout.Project, parent: RequestNodeID?, depth: Int, isShown: Bool) {
        var index = 0
        for node in children {
            if source == .node(project.id, node.id) {
                origin = .node(project.id, parent: parent, index: index)
                sourceNodes = Self.subtree(of: node)
                continue
            }
            let item = SidebarItem.node(project.id, node.id)
            switch node {
            case .request:
                if isShown {
                    rows.append(.init(item: item, kind: .request, depth: depth, parent: parent, index: index, acceptsNodes: project.acceptsNodes))
                }
            case .folder(let folder):
                let isExpanded = isFolderExpanded(project.id, folder.id)
                if isShown {
                    let hasVisibleChildren = isExpanded && folder.children.contains { source != .node(project.id, $0.id) }
                    rows.append(.init(
                        item: item,
                        kind: .folder(isExpanded: isExpanded, hasVisibleChildren: hasVisibleChildren),
                        depth: depth,
                        parent: parent,
                        index: index,
                        acceptsNodes: project.acceptsNodes
                    ))
                }
                add(folder.children, of: project, parent: folder.id, depth: depth + 1, isShown: isShown && isExpanded)
            }
            index += 1
        }
    }

    private static func subtree(of node: RequestNode) -> Set<RequestNodeID> {
        guard case .folder(let folder) = node else {
            return [node.id]
        }
        return folder.children.reduce(into: [node.id]) { $0.formUnion(subtree(of: $1)) }
    }
}
