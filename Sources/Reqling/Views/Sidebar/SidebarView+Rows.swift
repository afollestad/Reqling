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
                SidebarNodeRow(node: node, projectID: project.id, isFiltering: isFiltering, model: model)
            }
        } label: {
            SidebarProjectLabel(project: project, requestCount: section.requestCount, model: model)
        }
    }
}

private struct SidebarProjectLabel: View {
    /// The disclosure caret ends 3pt before its label; this widens that to the 8pt between the icon and the name.
    private static let caretGap: CGFloat = 5

    let project: LibraryProject
    let requestCount: Int
    let model: AppModel
    @Environment(\.appAccent) private var accent

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
            Text(project.name)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isAvailable {
                SidebarCount(count: requestCount)
            } else {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .help(unavailableReason ?? project.url.path)
        .tag(SidebarItem.project(project.id))
        .contextMenu { SidebarProjectMenu(project: project, model: model) }
        .dropDestination(for: SidebarDragItem.self) { items, _ in
            return drop(items, into: nil)
        }
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

    private func drop(_ items: [SidebarDragItem], into parent: RequestNodeID?) -> Bool {
        var moved = false
        for item in items where item.projectID == project.id && model.canMove(item.nodeID, in: project.id, into: parent) {
            model.move(item.nodeID, in: project.id, to: parent, at: nil)
            moved = true
        }
        return moved
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
            Button("Environments…") { model.sheet = .environments(project.id) }
            Button("Project Settings…") { model.sheet = .projectSettings(project.id) }
            Button("Rename…") { model.beginRename(nil, in: project.id) }
            Divider()
        }
        Button("Reveal in Finder") { model.revealProject(project.id) }
        Button("Remove from Reqling") { model.removeProject(project.id) }
        if project.document != nil {
            Button("Move to Trash…", role: .destructive) { model.projectPendingDeletion = project.id }
        }
    }
}

/// A folder (with its children) or a request.
struct SidebarNodeRow: View {
    let node: RequestNode
    let projectID: ProjectID
    let isFiltering: Bool
    let model: AppModel

    var body: some View {
        switch node {
        case .request(let request):
            SidebarRequestLabel(request: request, projectID: projectID, model: model)
        case .folder(let folder):
            DisclosureGroup(isExpanded: Binding(
                get: { isFiltering || model.isExpanded(folder: folder.id, in: projectID) },
                set: { if !isFiltering { model.setExpanded($0, folder: folder.id, in: projectID) } }
            )) {
                ForEach(folder.children) { child in
                    SidebarNodeRow(node: child, projectID: projectID, isFiltering: isFiltering, model: model)
                }
            } label: {
                SidebarFolderLabel(folder: folder, projectID: projectID, model: model)
            }
        }
    }
}

private struct SidebarRequestLabel: View {
    let request: RequestItem
    let projectID: ProjectID
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            RequestKindPill(kind: request.kind)
            Text(request.name)
                .lineLimit(1)
        }
        .tag(SidebarItem.node(projectID, request.id))
        .contextMenu { SidebarItemMenu(nodeID: request.id, projectID: projectID, request: request.kind.name, model: model) }
        .draggable(SidebarDragItem(projectID: projectID, nodeID: request.id))
        .dropDestination(for: SidebarDragItem.self) { items, _ in
            // Dropping on a request places the item just before it.
            guard let document = model.library.document(projectID) else {
                return false
            }
            let parent = document.parentID(of: request.id)
            var moved = false
            let movable = items.filter { item in
                item.projectID == projectID && item.nodeID != request.id && model.canMove(item.nodeID, in: projectID, into: parent)
            }
            for item in movable {
                let siblings = (document.children(of: parent) ?? []).filter { $0.id != item.nodeID }
                model.move(item.nodeID, in: projectID, to: parent, at: siblings.firstIndex { $0.id == request.id })
                moved = true
            }
            return moved
        }
    }
}

private struct SidebarFolderLabel: View {
    let folder: RequestFolder
    let projectID: ProjectID
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(folder.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarCount(count: folder.children.count)
        }
            .tag(SidebarItem.node(projectID, folder.id))
            .contextMenu { SidebarItemMenu(nodeID: folder.id, projectID: projectID, request: nil, model: model) }
            .draggable(SidebarDragItem(projectID: projectID, nodeID: folder.id))
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                var moved = false
                for item in items where item.projectID == projectID && model.canMove(item.nodeID, in: projectID, into: folder.id) {
                    model.move(item.nodeID, in: projectID, to: folder.id, at: nil)
                    moved = true
                }
                return moved
            }
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
        Divider()
        Button("Rename…") { model.beginRename(nodeID, in: projectID) }
        Button("Duplicate") { model.duplicate(nodeID, in: projectID) }
        if request == .http {
            Button("Copy as cURL") {
                model.selection = .node(projectID, nodeID)
                model.editor?.asHTTP?.copyAsCurl()
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(nodeID, in: projectID) }
    }
}

/// A secondary count at the trailing edge of a project or folder row.
private struct SidebarCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(count) item\(count == 1 ? "" : "s")")
    }
}

/// A compact method name, or "gRPC", on a tinted pill, sized so request names line up.
private struct RequestKindPill: View {
    let kind: RequestKind

    var body: some View {
        Group {
            switch kind {
            case .http(let spec):
                MethodBadge(method: spec.method, compact: true)
            case .grpc:
                GRPCBadge(compact: true)
            }
        }
        .frame(width: 38, height: 16)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius, style: .continuous)
                .fill(tint.opacity(0.16))
        )
    }

    private var tint: Color {
        switch kind {
        case .http(let spec): MethodBadge.color(for: spec.method)
        case .grpc: GRPCBadge.color
        }
    }
}
