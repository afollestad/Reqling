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
                Text("Projects")
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
        .toolbar {
            ToolbarItem(id: MainToolbarItemID.addProject, placement: .automatic) {
                SidebarAddProjectMenu(model: model)
            }
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

/// The toolbar's add menu, beside the sidebar toggle. It stays while the library is empty: the empty state offers the
/// same actions, but the toolbar is the one place they are always found.
private struct SidebarAddProjectMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("New Project…") { model.sheet = .newProject }
            Button("Add Project Folder…") { model.openProjectFolder() }
        } label: {
            Label("Add a Project", systemImage: "plus")
        }
        .menuIndicator(.hidden)
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
            .help("More ways to add")
            .accessibilityLabel("More ways to add")
            .iconButtonChrome()
        }
        .padding(.horizontal, 12)
        // The menu's icon tile carries its own padding, so the bar's vertical inset is that much smaller.
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
