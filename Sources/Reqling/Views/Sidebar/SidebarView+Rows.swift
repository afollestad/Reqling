import ReqlingKit
import SwiftUI

/// One project: a disclosure row whose children are its (filtered) top-level items. While filtering, everything is
/// shown expanded and expansion changes are not remembered.
struct SidebarProjectGroup: View {
    let section: SidebarSection
    let isFiltering: Bool
    let model: AppModel

    var body: some View {
        let project = section.project
        DisclosureGroup(isExpanded: Binding(
            get: { isFiltering || model.isExpanded(project.id) },
            set: { if !isFiltering { model.setExpanded($0, project: project.id) } }
        )) {
            ForEach(section.items) { node in
                SidebarNodeRow(
                    node: node, projectID: project.id, depth: 0, isFiltering: isFiltering, isMovable: isMovable, model: model
                )
            }
        } label: {
            SidebarProjectLabel(project: project, requestCount: section.requestCount, isFiltering: isFiltering, model: model)
        }
    }

    /// Whether its folders and requests can be dragged: never while filtering, whose shown order isn't the saved one,
    /// and only out of a project that loaded and can be written.
    private var isMovable: Bool {
        !isFiltering && section.project.document != nil && !section.project.isReadOnly
    }
}

private struct SidebarProjectLabel: View {
    /// The disclosure caret ends 3pt before its label; this widens that to the 8pt between the icon and the name.
    private static let caretGap: CGFloat = 5

    let project: LibraryProject
    let requestCount: Int
    let isFiltering: Bool
    let model: AppModel
    @Environment(\.appAccent) private var accent
    @Environment(SidebarDragController.self) private var drag

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius, style: .continuous)
                    .fill(isAvailable ? Color(nsColor: accent).gradient : Color.orange.gradient)
                Image(systemName: isAvailable ? "shippingbox.fill" : "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            .padding(.leading, Self.caretGap)
            .accessibilityHidden(true)
            SidebarRowName(item: .project(project.id), name: project.name, isEmphasized: true, model: model)
            Spacer(minLength: 4)
            if isAvailable {
                SidebarCount(count: requestCount)
            } else {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .sidebarRowClick(isEnabled: drag.isIdle) { drag.click(item) }
        .sidebarDragGeometry(item)
        .sidebarDragFade(item, drag: drag)
        // A project that didn't load still reorders; its place in the sidebar is all a drag changes.
        .sidebarDragSource(item, drag: drag, isEnabled: !isFiltering && model.renaming == nil)
        .help(unavailableReason ?? project.url.path)
        .tag(item)
        .contextMenu { SidebarProjectMenu(project: project, model: model) }
    }

    private var item: SidebarItem {
        .project(project.id)
    }

    private var isAvailable: Bool {
        project.document != nil
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = project.status {
            return reason
        }
        return nil
    }
}

private struct SidebarProjectMenu: View {
    let project: LibraryProject
    let model: AppModel

    var body: some View {
        if project.document != nil {
            Button("New Request") { model.selection = .project(project.id); model.newRequest(in: project.id) }
            Button("New Folder") { model.selection = .project(project.id); model.newFolder(in: project.id) }
            Divider()
            Button("Run Project…") { model.openBatchRun(BatchRunScope(projectID: project.id, folderID: nil)) }
                .disabled(!model.canRunBatch(BatchRunScope(projectID: project.id, folderID: nil)))
            Divider()
            Button("Environments…") { model.sheet = .environments(project.id) }
            Button("Project Settings…") { model.sheet = .projectSettings(project.id) }
            Button("Rename") { model.beginRename(.project(project.id)) }
                .disabled(!model.canRename(.project(project.id)))
            Button("Clear Run History…") { model.requestClearHistory(of: project.id) }
            Divider()
        }
        Button("Reveal in Finder") { model.revealProject(project.id) }
        Button("Remove from Reqling") { model.removeProject(project.id) }
        if project.document != nil {
            Button("Move to Trash…", role: .destructive) { model.requestTrash(.project(project.id)) }
        }
    }
}

/// A request, or a folder followed by its children while it is open. A folder is a row of its own rather than a
/// `DisclosureGroup`, whose caret the outline draws ahead of the folder's pill, out of line with its sibling requests'
/// pills. So a click on the row or its pill opens and closes it, rows indent themselves by `depth`, and
/// `AppModel.expandFolder(at:)` and `collapseFolderOrSelectParent(at:)` stand in for the outline's ← and →.
struct SidebarNodeRow: View {
    /// The outline's own step between levels, which a project's rows still take from it.
    nonisolated static let indentPerLevel: CGFloat = 13

    let node: RequestNode
    let projectID: ProjectID
    /// The folders between this row and its project.
    let depth: Int
    /// Filtering shows every folder open and remembers no change.
    let isFiltering: Bool
    /// Whether the row can be dragged (`SidebarProjectGroup`).
    let isMovable: Bool
    let model: AppModel

    var body: some View {
        switch node {
        case .request(let request):
            SidebarRequestLabel(request: request, projectID: projectID, indent: indent, isMovable: isMovable, model: model)
        case .folder(let folder):
            let isExpanded = isFiltering || model.isExpanded(folder: folder.id, in: projectID)
            SidebarFolderLabel(
                folder: folder,
                projectID: projectID,
                indent: indent,
                isExpanded: isExpanded,
                isFiltering: isFiltering,
                isMovable: isMovable,
                model: model
            )
            if isExpanded {
                ForEach(folder.children) { child in
                    SidebarNodeRow(
                        node: child, projectID: projectID, depth: depth + 1, isFiltering: isFiltering, isMovable: isMovable, model: model
                    )
                }
            }
        }
    }

    private var indent: CGFloat {
        CGFloat(depth) * Self.indentPerLevel
    }

    /// Whether a click on a folder's row opens or closes it as well as selecting it. Filtering shows every folder open;
    /// a rename's field takes clicks for itself; Control-click opens the menu. A double-click's second click is left
    /// alone, or the folder would open and close again at once.
    static func clickToggles(isFiltering: Bool, isRenaming: Bool, modifiers: NSEvent.ModifierFlags, clickCount: Int) -> Bool {
        !isFiltering && !isRenaming && !modifiers.contains(.control) && clickCount <= 1
    }
}

private struct SidebarRequestLabel: View {
    let request: RequestItem
    let projectID: ProjectID
    let indent: CGFloat
    let isMovable: Bool
    let model: AppModel
    @Environment(SidebarDragController.self) private var drag

    var body: some View {
        HStack(spacing: 8) {
            RequestKindPill(kind: request.kind)
            SidebarRowName(item: .node(projectID, request.id), name: request.name, model: model)
            Spacer(minLength: 4)
            SidebarAccessories {
                SidebarBatchRunBadge(itemID: request.id, isFolder: false, batches: model.batches)
                if !request.scripts.isEmpty {
                    SidebarScriptsBadge()
                }
            }
        }
        .padding(.leading, indent)
        .sidebarRowClick(isEnabled: drag.isIdle) { drag.click(item) }
        .sidebarDragGeometry(item)
        .sidebarDragFade(item, drag: drag)
        .sidebarDragSource(item, drag: drag, isEnabled: isMovable && model.renaming == nil)
        .tag(item)
        .contextMenu { SidebarItemMenu(nodeID: request.id, projectID: projectID, request: request.kind.name, model: model) }
    }

    private var item: SidebarItem {
        .node(projectID, request.id)
    }
}

private struct SidebarFolderLabel: View {
    let folder: RequestFolder
    let projectID: ProjectID
    let indent: CGFloat
    let isExpanded: Bool
    let isFiltering: Bool
    let isMovable: Bool
    let model: AppModel
    @Environment(SidebarDragController.self) private var drag

    var body: some View {
        HStack(spacing: 8) {
            SidebarFolderToggle(isExpanded: isExpanded, toggle: toggle)
                .disabled(isFiltering)
            SidebarRowName(item: item, name: folder.name, model: model)
            Spacer(minLength: 4)
            SidebarAccessories {
                SidebarBatchRunBadge(itemID: folder.id, isFolder: true, batches: model.batches)
                if !folder.scripts.isEmpty {
                    SidebarScriptsBadge()
                }
                SidebarCount(count: folder.children.count)
            }
        }
        .padding(.leading, indent)
        // A click on the row selects the folder and opens or closes it too. The pill, a button of its own, takes its
        // own clicks, opening or closing the folder without selecting it, as the outline's caret did.
        .sidebarRowClick(isEnabled: drag.isIdle) {
            // Decided first: giving the table the keyboard ends a rename, which this click must not toggle.
            let toggles = togglesOnClick
            drag.click(item)
            if toggles {
                toggle()
            }
        }
        .sidebarDragGeometry(item)
        .sidebarDragFade(item, drag: drag)
        .sidebarDragSource(item, drag: drag, isEnabled: isMovable && model.renaming == nil)
        .tag(item)
        .contextMenu { SidebarItemMenu(nodeID: folder.id, projectID: projectID, request: nil, model: model) }
    }

    private var item: SidebarItem {
        .node(projectID, folder.id)
    }

    /// Reads the model rather than `isExpanded`, which a click can outrun before the row redraws.
    private func toggle() {
        guard drag.isIdle else {
            return
        }
        model.setExpanded(!model.isExpanded(folder: folder.id, in: projectID), folder: folder.id, in: projectID)
    }

    private var togglesOnClick: Bool {
        SidebarNodeRow.clickToggles(
            isFiltering: isFiltering,
            isRenaming: model.renaming == item,
            modifiers: NSEvent.modifierFlags,
            clickCount: NSApp.currentEvent?.clickCount ?? 1
        )
    }
}

/// Marks a request or folder with scripts of its own.
private struct SidebarScriptsBadge: View {
    var body: some View {
        Image(systemName: "curlybraces")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: AppMetrics.sidebarAccessoryWidth)
            .help("Has scripts")
            .accessibilityLabel("Has scripts")
    }
}

private struct SidebarItemMenu: View {
    let nodeID: RequestNodeID
    let projectID: ProjectID
    /// The request's protocol; `nil` for a folder.
    let request: RequestKind.Name?
    let model: AppModel

    var body: some View {
        Button("New Request") { model.selection = .node(projectID, nodeID); model.newRequest(in: projectID) }
        Button("New Folder") { model.selection = .node(projectID, nodeID); model.newFolder(in: projectID) }
        if request == nil {
            Button("Run Folder…") { model.openBatchRun(BatchRunScope(projectID: projectID, folderID: nodeID)) }
                .disabled(!model.canRunBatch(BatchRunScope(projectID: projectID, folderID: nodeID)))
        }
        Divider()
        Button("Rename") { model.beginRename(.node(projectID, nodeID)) }
            .disabled(!model.canRename(.node(projectID, nodeID)))
        Button("Duplicate") { model.duplicate(nodeID, in: projectID) }
        if request == .http {
            Button("Copy as cURL") {
                model.selection = .node(projectID, nodeID)
                model.editor?.asHTTP?.copyAsCurl()
            }
        }
        if request != nil {
            Button("Clear Run History…") { model.requestClearHistory(of: nodeID, in: projectID) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.requestTrash(.node(projectID, nodeID)) }
    }
}

/// A row's trailing accessories, each in its own `AppMetrics.sidebarAccessoryWidth` cell and packed together, so the
/// last cell of every row lines up in one column at the trailing edge.
private struct SidebarAccessories<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
    }
}

/// A secondary count at the trailing edge of a project or folder row. Never compressed: the name truncates first, and a
/// rename field, which outranks it for width, would otherwise squeeze it to nothing.
private struct SidebarCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            // A minimum, so a count too wide for the cell grows it rather than truncating.
            .frame(minWidth: AppMetrics.sidebarAccessoryWidth)
            .accessibilityLabel("\(count) item\(count == 1 ? "" : "s")")
    }
}

/// A request's compact HTTP method, "gRPC", or "WS" on a tinted pill, as the sidebar and the run sheet show it.
struct RequestKindPill: View {
    let kind: RequestKind

    var body: some View {
        SidebarPill(tint: tint) {
            switch kind {
            case .http(let spec):
                MethodBadge(method: spec.method, compact: true)
            case .grpc:
                GRPCBadge(compact: true)
            case .webSocket:
                WebSocketBadge(compact: true)
            }
        }
    }

    private var tint: Color {
        switch kind {
        case .http(let spec): MethodBadge.color(for: spec.method)
        case .grpc: GRPCBadge.color
        case .webSocket: WebSocketBadge.color
        }
    }
}

/// The pill under a request's kind or a folder's glyph. Every one is the same width, so the names beside them line up:
/// in the sidebar, a level's folders and requests share one column.
struct SidebarPill<Content: View>: View {
    let tint: Color
    var fillOpacity = 0.16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: 38, height: 16)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius, style: .continuous)
                    .fill(BadgeTint(color: tint).opacity(fillOpacity))
            )
    }
}
