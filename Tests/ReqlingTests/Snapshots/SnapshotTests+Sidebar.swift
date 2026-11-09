import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    func testSidebar() throws {
        // Unselected: List's vibrant selection highlight does not survive an offscreen capture.
        _ = try SnapshotProject.make(in: fixture)

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    func testSidebarFiltered() throws {
        _ = try SnapshotProject.make(in: fixture)
        fixture.model.sidebar.query = "users"
        fixture.model.sidebar.filter = RequestFilter(methods: [.get])

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 300))
    }

    /// A folder renamed in place: the field boxes its name where the label was, and its count stays put.
    func testSidebarRenaming() throws {
        let project = try SnapshotProject.make(in: fixture)

        assertBothAppearances(sidebar(renaming: .node(project.id, project.folder)), size: CGSize(width: 280, height: 360))
    }

    /// A closed folder's outline glyph on a grey pill, where an open one's fills on the accent.
    func testSidebarClosedFolder() throws {
        let project = try SnapshotProject.make(in: fixture)
        fixture.model.setExpanded(false, folder: project.folder, in: project.id)

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 300))
    }

    /// The folder pill closed and open in each state, the last on a selected row's accent highlight, which an open
    /// pill's own accent would vanish into. Hover, press, and the highlight can't be triggered offscreen, so each is set
    /// on `SidebarFolderTile` directly.
    func testSidebarFolderPillStates() {
        assertBothAppearances(SidebarFolderPillGrid(), size: CGSize(width: 300, height: 100))
    }

    /// Each request pill as it is, then on a selected row's accent highlight, where PATCH's purple and WebSocket's indigo
    /// would otherwise vanish.
    func testSidebarRequestPillsOnASelectedRow() {
        assertBothAppearances(SidebarRequestPillRows(), size: CGSize(width: 420, height: 90))
    }

    func testSidebarEmpty() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    /// The sidebar's minimum width, where the actions stack instead of sharing a row.
    func testSidebarEmptyNarrow() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 220, height: 360))
    }

    /// Begins the rename for each appearance: closing one appearance's window ends it, as a row leaving the window does.
    private func sidebar(renaming item: SidebarItem) -> SidebarView {
        fixture.model.beginRename(item)
        return SidebarView(model: fixture.model)
    }
}

private struct SidebarRequestPillRows: View {
    private static let kinds: [RequestKind] = [HTTPMethod.get, .post, .put, .patch, .delete, HTTPMethod(rawValue: "PURGE")]
        .map { .http(HTTPRequestSpec(method: $0)) } + [.grpc(GRPCRequestSpec()), .webSocket(WebSocketRequestSpec())]

    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(spacing: 8) {
            pills
            pills
                .padding(6)
                .background(RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius).fill(Color(nsColor: accent)))
                .environment(\.backgroundProminence, .increased)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pills: some View {
        HStack(spacing: 6) {
            ForEach(Self.kinds, id: \.self) { kind in
                RequestKindPill(kind: kind)
            }
        }
    }
}

private struct SidebarFolderPillGrid: View {
    @Environment(\.appAccent) private var accent

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(["Idle", "Hover", "Pressed", "Selected"], id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach([false, true], id: \.self) { isOpen in
                GridRow {
                    tile(isOpen: isOpen)
                    tile(isOpen: isOpen, isHovered: true)
                    tile(isOpen: isOpen, isPressed: true)
                    tile(isOpen: isOpen)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius).fill(Color(nsColor: accent)))
                        .environment(\.backgroundProminence, .increased)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(isOpen: Bool, isHovered: Bool = false, isPressed: Bool = false) -> some View {
        SidebarFolderTile(isOpen: isOpen, isHovered: isHovered, isPressed: isPressed) {
            SidebarFolderGlyph(isOpen: isOpen)
        }
    }
}
