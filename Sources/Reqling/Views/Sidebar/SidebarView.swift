import CoreTransferable
import ReqlingKit
import SwiftUI
import UniformTypeIdentifiers

/// Projects with their folders and requests, under a filter field. Selection, expansion, and every edit route
/// through `AppModel`; filtering through `SidebarViewModel`.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        let sidebar = model.sidebar
        let sections = sidebar.sections
        List(selection: $model.selection) {
            Section {
                ForEach(sections) { section in
                    SidebarProjectGroup(section: section, isFiltering: sidebar.isFiltering, model: model)
                }
            } header: {
                SidebarProjectsHeader(model: model)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: moveSelectionToTrash)
        .overlay {
            if model.library.projects.isEmpty {
                SidebarEmptyState(model: model)
            } else if sections.isEmpty {
                SidebarNoMatches(sidebar: sidebar)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSearchBar(sidebar: sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(model: model)
        }
    }

    /// The Delete key and Edit ▸ Delete take the same path as the row's context menu: an item goes straight to the
    /// Trash, and a project asks first, so the keyboard reaches what was otherwise mouse-only.
    private func moveSelectionToTrash() {
        switch model.selection {
        case .node(let project, let node)?:
            model.delete(node, in: project)
        case .project(let project)? where model.library.document(project) != nil:
            model.projectPendingDeletion = project
        default:
            break
        }
    }
}

/// A sidebar row's drag payload: an item within one project.
struct SidebarDragItem: Codable, Transferable {
    let projectID: ProjectID
    let nodeID: RequestNodeID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct SidebarProjectsHeader: View {
    let model: AppModel

    var body: some View {
        let isEmpty = model.library.projects.isEmpty
        // Baseline alignment centers the glyph on the letters; centering would use the line box, which reserves
        // descender space below them and leaves the glyph sitting low.
        HStack(alignment: .firstTextBaseline) {
            Text("Projects")
            Spacer()
            // The empty state offers the same actions. Hidden rather than removed, so the header keeps its height
            // when the first project arrives.
            SidebarHeaderAddMenu(model: model)
                .opacity(isEmpty ? 0 : 1)
                .disabled(isEmpty)
                .accessibilityHidden(isEmpty)
        }
    }
}

/// The header's add menu, drawn as Alveary's sidebar header actions are: a glyph whose circle fills while hovered. A
/// section header's content runs closer to the edge than a row's selection, so the trailing padding pulls the circle in
/// until its edge meets the selection's, which also centers it over the rows' count column.
private struct SidebarHeaderAddMenu: View {
    static let size: CGFloat = 20
    static let trailingAlignment: CGFloat = 8

    let model: AppModel
    @State private var isHovering = false

    var body: some View {
        Menu {
            Button("New Project…") { model.sheet = .newProject }
            Button("Add Project Folder…") { model.openProjectFolder() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(isHovering ? 0.9 : 0.68))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, Self.trailingAlignment)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help("Create a project, or add an existing project folder")
        .accessibilityLabel("Add a project")
    }
}

private struct SidebarEmptyState: View {
    let model: AppModel

    var body: some View {
        CompactEmptyState(
            systemImage: "shippingbox",
            title: "No Projects",
            message: "A project holds your requests and their environments."
        ) {
            Button("New Project…") { model.sheet = .newProject }
                .buttonStyle(.borderedProminent)
            Button("Add Project Folder…") { model.openProjectFolder() }
        }
    }
}

private struct SidebarNoMatches: View {
    let sidebar: SidebarViewModel

    var body: some View {
        CompactEmptyState(
            systemImage: "line.3.horizontal.decrease.circle",
            title: "No Matches",
            message: "No project, folder, or request matches the filter."
        ) {
            Button("Clear Filter") { sidebar.clearFilters() }
        }
    }
}

private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.newRequest()
            } label: {
                Label("New Request", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.activeProjectID == nil)
            .help("Add a request beside the selection")
            Spacer()
            Menu {
                Button("New Folder") { model.newFolder() }
                    .disabled(model.activeProjectID == nil)
                Divider()
                Button("New Project…") { model.sheet = .newProject }
                Button("Add Project Folder…") { model.openProjectFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More ways to add")
            .accessibilityLabel("More ways to add")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
