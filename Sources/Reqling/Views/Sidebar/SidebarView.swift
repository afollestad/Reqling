import AppKit
import CoreTransferable
import ReqlingKit
import SwiftUI
import UniformTypeIdentifiers

/// Projects with their folders and requests, under a filter field. Selection, expansion, and every edit route
/// through `AppModel`; filtering through `SidebarViewModel`.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var presence = SidebarPresence()

    var body: some View {
        let sidebar = model.sidebar
        let sections = sidebar.sections
        ScrollViewReader { proxy in
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
            .background { SidebarPresenceReader(presence: presence) }
            .onChange(of: model.renaming) { _, item in
                if let item {
                    reveal(item, with: proxy)
                }
            }
        }
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
            VStack(spacing: 0) {
                SidebarBatchRunBar(model: model)
                SidebarFooter(model: model)
            }
        }
        .toolbar {
            ToolbarItem(id: MainToolbarItemID.addProject, placement: .automatic) {
                SidebarAddProjectMenu(model: model)
            }
        }
    }

    /// Brings a row being renamed into view, or ends the rename when the sidebar is collapsed. A new request or folder
    /// can land below the fold or behind a collapsed column, where no row and so no field exists yet; left alone, the
    /// field would appear whenever the row did and take the keyboard from whatever had it by then. A visible row stays.
    private func reveal(_ item: SidebarItem, with proxy: ScrollViewProxy) {
        guard presence.isOnScreen else {
            model.endRename(item, to: nil)
            return
        }
        switch item {
        case .project(let project):
            proxy.scrollTo(project)
        case .node(_, let node):
            proxy.scrollTo(node)
        }
    }

    /// The Delete key and Edit ▸ Delete take the same path as the row's context menu, asking before anything moves to
    /// the Trash, so the keyboard reaches what was otherwise mouse-only.
    private func moveSelectionToTrash() {
        if let selection = model.selection {
            model.requestTrash(selection)
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
            Button("Import Postman Collection…") { model.sheet = .importPostman }
        } label: {
            Label("Add a Project", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("Create a project, add an existing project folder, or import a Postman collection")
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
            Button("Import Postman Collection…") { model.sheet = .importPostman }
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
                Button("Import Postman Collection…") { model.sheet = .importPostman }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More ways to add")
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

/// Where the sidebar's `List` sits in AppKit, to ask whether it is on screen when that matters rather than mirror it in
/// state: `NavigationSplitView` hides a collapsed column instead of removing it.
@MainActor
private final class SidebarPresence {
    weak var view: NSView?

    var isOnScreen: Bool {
        guard let view else {
            return false
        }
        return view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }
}

private struct SidebarPresenceReader: NSViewRepresentable {
    let presence: SidebarPresence

    func makeNSView(context: Context) -> SidebarPresenceView {
        let view = SidebarPresenceView()
        presence.view = view
        return view
    }

    func updateNSView(_ view: SidebarPresenceView, context: Context) {
        presence.view = view
    }
}

private final class SidebarPresenceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks go to the list as before.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
