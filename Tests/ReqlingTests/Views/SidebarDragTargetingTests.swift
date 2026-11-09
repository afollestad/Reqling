import CoreGraphics
import ReqlingKit
import XCTest

@testable import Reqling

/// Where a sidebar drop lands for a pointer, over rows laid out as the real list lays them: a 32pt pitch whose 16pt
/// content frames start at one x for every folder and request, the dragged rows still showing.
final class SidebarDragTargetingTests: XCTestCase {
    func testARequestsUpperHalfInsertsAboveItAndItsLowerHalfBelow() throws {
        let fixture = Fixture(.request("A"), .request("B"), .request("C"))
        let layout = try fixture.layout(dragging: "C")

        XCTAssertEqual(fixture.target(layout, at: "A", 0.3), .node(fixture.projectID, parent: nil, index: 0))
        XCTAssertEqual(fixture.target(layout, at: "A", 0.7), .node(fixture.projectID, parent: nil, index: 1))
        XCTAssertNil(fixture.target(layout, at: "B", 0.7), "Below B is where C already is")
    }

    /// The dragged rows are left out of the layout, so an index past them is already counted without the dragged item.
    func testIndicesCountWithoutTheDraggedItem() throws {
        let fixture = Fixture(.request("A"), .request("B"), .request("C"))
        let layout = try fixture.layout(dragging: "A")

        XCTAssertEqual(fixture.target(layout, at: "C", 0.7), .node(fixture.projectID, parent: nil, index: 2))
        XCTAssertNil(fixture.target(layout, at: "A", 0.5), "The dragged row takes no drop")
    }

    func testAClosedFoldersMiddleDropsIntoItAndItsEdgesInsertBesideIt() throws {
        let fixture = Fixture(.request("A"), .folder("F", children: [.request("X")]), .request("B"), .request("C"))
        let layout = try fixture.layout(dragging: "C")

        XCTAssertEqual(fixture.target(layout, at: "F", 0.1), .node(fixture.projectID, parent: nil, index: 1))
        XCTAssertEqual(fixture.target(layout, at: "F", 0.9), .node(fixture.projectID, parent: nil, index: 2))
        let into = try XCTUnwrap(fixture.candidate(layout, at: "F", 0.5))
        XCTAssertEqual(into.target, .into(fixture.item("F")))
        XCTAssertTrue(into.opensAfterPause, "A closed folder opens when the pointer rests on it")
        XCTAssertNil(into.line)
    }

    /// Below an open folder's row is its first place, which the drop into it takes as well.
    func testAnOpenFoldersLowerPartDropsIntoIt() throws {
        let fixture = Fixture(.folder("F", children: [.request("X")], isExpanded: true), .request("B"))
        let layout = try fixture.layout(dragging: "B")

        let into = try XCTUnwrap(fixture.candidate(layout, at: "F", 0.9))
        XCTAssertEqual(into.target, .into(fixture.item("F")))
        XCTAssertFalse(into.opensAfterPause)
        XCTAssertEqual(fixture.target(layout, at: "X", 0.3), .node(fixture.projectID, parent: fixture.id("F"), index: 0))
    }

    /// Below an open folder's last row, the pointer's x picks between its last place and the place after it.
    func testTheLevelBelowAnOpenFoldersLastRowFollowsThePointer() throws {
        let fixture = Fixture(
            .folder("F", children: [.request("X"), .request("Y")], isExpanded: true), .request("B"), .request("C")
        )
        let layout = try fixture.layout(dragging: "C")

        let inside = try XCTUnwrap(fixture.candidate(layout, at: "Y", 0.7, pointerX: Fixture.nodeX + 20))
        let after = try XCTUnwrap(fixture.candidate(layout, at: "Y", 0.7, pointerX: Fixture.nodeX + 2))

        XCTAssertEqual(inside.target, .node(fixture.projectID, parent: fixture.id("F"), index: 2))
        XCTAssertEqual(inside.line?.x, Fixture.nodeX + SidebarNodeRow.indentPerLevel)
        XCTAssertEqual(after.target, .node(fixture.projectID, parent: nil, index: 1))
        XCTAssertEqual(after.line?.x, Fixture.nodeX)
        XCTAssertEqual(
            fixture.target(layout, at: "Y", 0.7, pointerX: Fixture.nodeX + 200), inside.target, "A level deeper than the row's is clamped"
        )
    }

    func testADraggedFolderAndItsContentsTakeNoDropAndItCantMoveIntoItself() throws {
        let fixture = Fixture(.folder("F", children: [.request("X")], isExpanded: true), .request("B"))
        let layout = try fixture.layout(dragging: "F")

        XCTAssertNil(fixture.target(layout, at: "X", 0.5))
        XCTAssertFalse(layout.rows.contains { $0.item == fixture.item("X") })
        XCTAssertEqual(layout.sourceNodes, [fixture.id("F"), fixture.id("X")])
    }

    func testAProjectRowDropsIntoItFirstUnlessItCantTakeIt() throws {
        let fixture = Fixture(.request("A"), .request("B"))
        let other = Fixture.Project(id: ProjectID(), items: [])
        let readOnly = Fixture.Project(id: ProjectID(), items: [], acceptsNodes: false)
        let projects = [fixture.project, other, readOnly]
        let layout = try fixture.layout(dragging: "B", projects: projects)

        XCTAssertEqual(fixture.target(layout, at: .project(other.id), 0.5, projects: projects), .into(.project(other.id)))
        XCTAssertNil(fixture.target(layout, at: .project(readOnly.id), 0.5, projects: projects))
        XCTAssertEqual(fixture.target(layout, at: .project(fixture.projectID), 0.5, projects: projects), .into(.project(fixture.projectID)))

        let first = try fixture.layout(dragging: "A", projects: projects)
        XCTAssertNil(fixture.target(first, at: .project(fixture.projectID), 0.5, projects: projects), "A is already first")
    }

    func testAFolderOrRequestInAProjectThatCantChangeHasNoDrag() {
        let fixture = Fixture(.request("A"), acceptsNodes: false)

        XCTAssertNil(SidebarDragLayout.make(source: fixture.item("A"), projects: [fixture.project.layoutProject]) { _, _ in false })
        XCTAssertNotNil(
            SidebarDragLayout.make(source: .project(fixture.projectID), projects: [fixture.project.layoutProject]) { _, _ in false },
            "The project itself still reorders"
        )
    }

    /// A project inserts only at another project's edges, never among its rows.
    func testAProjectInsertsOnlyAtAnotherProjectsEdges() throws {
        let first = Fixture.Project(id: ProjectID(), items: [.request(RequestItem(name: "A", kind: .http(HTTPRequestSpec())))])
        let second = Fixture.Project(id: ProjectID(), items: [], isExpanded: false)
        let third = Fixture.Project(id: ProjectID(), items: [])
        let fixture = Fixture(projects: [first, second, third])
        let layout = try XCTUnwrap(SidebarDragLayout.make(
            source: .project(third.id), projects: fixture.projects.map(\.layoutProject)
        ) { _, _ in false })
        let rowA = SidebarItem.node(first.id, first.items[0].id)

        XCTAssertEqual(fixture.target(layout, at: .project(first.id), 0.3), .project(index: 0))
        XCTAssertNil(fixture.target(layout, at: .project(first.id), 0.7), "The middle of an open project takes no project")
        XCTAssertEqual(fixture.target(layout, at: rowA, 0.7), .project(index: 1))
        XCTAssertEqual(fixture.target(layout, at: .project(second.id), 0.3), .project(index: 1))
        XCTAssertNil(fixture.target(layout, at: .project(second.id), 0.7), "Below the second project is where the third already is")
    }

    func testTheBorderWrapsAFoldersRowAndOpenContents() throws {
        let fixture = Fixture(.folder("F", children: [.request("X"), .request("Y")], isExpanded: true), .request("B"))
        let layout = try fixture.layout(dragging: "B")

        let border = try XCTUnwrap(fixture.candidate(layout, at: "F", 0.5)?.border)

        XCTAssertEqual(border.minY, fixture.frame("F").minY)
        XCTAssertEqual(border.maxY, fixture.frame("Y").maxY)
    }

    /// A line resting on the boundary between two levels holds for a few points either way, so it doesn't flicker.
    func testATargetHoldsWithinTheRetentionSlop() throws {
        let fixture = Fixture(.folder("F", children: [.request("Y")], isExpanded: true), .request("B"), .request("C"))
        let layout = try fixture.layout(dragging: "C")
        let inside = SidebarDropTarget.node(fixture.projectID, parent: fixture.id("F"), index: 1)
        let boundary = Fixture.nodeX + SidebarNodeRow.indentPerLevel

        XCTAssertNotEqual(fixture.target(layout, at: "Y", 0.7, pointerX: boundary - 2), inside)
        XCTAssertEqual(fixture.target(layout, at: "Y", 0.7, pointerX: boundary - 2, retaining: inside), inside)
        XCTAssertNotEqual(fixture.target(layout, at: "Y", 0.7, pointerX: boundary - 6, retaining: inside), inside)
    }

    /// The dragged row still shows in the gap it left, so a line there sits beside it, on the pointer's side.
    func testALineBesideTheDraggedRowKeepsToThePointersSide() throws {
        let fixture = Fixture(.folder("F", children: [.request("X")], isExpanded: true), .request("A"))
        let other = Fixture.Project(id: ProjectID(), items: [])
        let projects = [fixture.project, other]
        let layout = try fixture.layout(dragging: "A", projects: projects)

        let candidate = try XCTUnwrap(fixture.candidate(layout, at: "X", 0.7, pointerX: Fixture.nodeX + 20, projects: projects))

        XCTAssertEqual(candidate.target, .node(fixture.projectID, parent: fixture.id("F"), index: 1))
        let line = try XCTUnwrap(candidate.line)
        XCTAssertEqual(line.y, (fixture.frame("X", projects: projects).maxY + fixture.frame("A", projects: projects).minY) / 2)
    }
}

/// One project's rows, framed as `SidebarDragGeometry` publishes them.
private struct Fixture {
    enum Node {
        case request(String)
        case folder(String, children: [Node], isExpanded: Bool = false)
    }

    struct Project {
        let id: ProjectID
        let items: [RequestNode]
        var acceptsNodes = true
        var isExpanded = true
        var expandedFolders: Set<RequestNodeID> = []

        var layoutProject: SidebarDragLayout.Project {
            SidebarDragLayout.Project(id: id, acceptsNodes: acceptsNodes, isExpanded: isExpanded, items: items)
        }
    }

    static let nodeX: CGFloat = 37
    static let projectX: CGFloat = 25
    static let pitch: CGFloat = 32
    static let rowHeight: CGFloat = 16
    static let visible = CGRect(x: 0, y: 0, width: 300, height: 2_000)

    let projects: [Project]
    private var ids: [String: RequestNodeID] = [:]

    init(_ nodes: Node..., acceptsNodes: Bool = true) {
        var ids: [String: RequestNodeID] = [:]
        var expanded: Set<RequestNodeID> = []
        func build(_ node: Node) -> RequestNode {
            switch node {
            case .request(let name):
                let item = RequestItem(name: name, kind: .http(HTTPRequestSpec()))
                ids[name] = item.id
                return .request(item)
            case .folder(let name, let children, let isExpanded):
                let folder = RequestFolder(name: name, children: children.map(build))
                ids[name] = folder.id
                if isExpanded {
                    expanded.insert(folder.id)
                }
                return .folder(folder)
            }
        }
        let items = nodes.map(build)
        self.projects = [Project(id: ProjectID(), items: items, acceptsNodes: acceptsNodes, expandedFolders: expanded)]
        self.ids = ids
    }

    init(projects: [Project]) {
        self.projects = projects
    }

    var project: Project {
        projects[0]
    }

    var projectID: ProjectID {
        project.id
    }

    func id(_ name: String) -> RequestNodeID {
        ids[name] ?? RequestNodeID()
    }

    func item(_ name: String) -> SidebarItem {
        .node(projectID, id(name))
    }

    func layout(dragging name: String, projects: [Project]? = nil) throws -> SidebarDragLayout {
        let projects = projects ?? self.projects
        let expanded = projects.reduce(into: Set<RequestNodeID>()) { $0.formUnion($1.expandedFolders) }
        return try XCTUnwrap(SidebarDragLayout.make(source: item(name), projects: projects.map(\.layoutProject)) { _, folder in
            expanded.contains(folder)
        })
    }

    /// Every shown row's frame, dragged rows included, in the order the list shows them.
    func frames(projects: [Project]? = nil) -> [SidebarItem: CGRect] {
        let projects = projects ?? self.projects
        var frames: [SidebarItem: CGRect] = [:]
        var row = 0
        func add(_ item: SidebarItem, leading: CGFloat) {
            frames[item] = CGRect(x: leading, y: CGFloat(row) * Self.pitch + (Self.pitch - Self.rowHeight) / 2, width: 250, height: Self.rowHeight)
            row += 1
        }
        func addNodes(_ nodes: [RequestNode], in project: Project) {
            for node in nodes {
                add(.node(project.id, node.id), leading: Self.nodeX)
                if case .folder(let folder) = node, project.expandedFolders.contains(folder.id) {
                    addNodes(folder.children, in: project)
                }
            }
        }
        for project in projects {
            add(.project(project.id), leading: Self.projectX)
            if project.isExpanded {
                addNodes(project.items, in: project)
            }
        }
        return frames
    }

    func frame(_ name: String, projects: [Project]? = nil) -> CGRect {
        frames(projects: projects)[item(name)] ?? .zero
    }

    /// The candidate with the pointer `fraction` of the way down `name`'s row, its 32pt slot.
    func candidate(
        _ layout: SidebarDragLayout,
        at name: String,
        _ fraction: CGFloat,
        pointerX: CGFloat = 150,
        retaining: SidebarDropTarget? = nil,
        projects: [Project]? = nil
    ) -> SidebarDropCandidate? {
        candidate(layout, at: item(name), fraction, pointerX: pointerX, retaining: retaining, projects: projects)
    }

    func candidate(
        _ layout: SidebarDragLayout,
        at item: SidebarItem,
        _ fraction: CGFloat,
        pointerX: CGFloat = 150,
        retaining: SidebarDropTarget? = nil,
        projects: [Project]? = nil
    ) -> SidebarDropCandidate? {
        let frames = frames(projects: projects)
        guard let frame = frames[item] else {
            XCTFail("No row for \(item)")
            return nil
        }
        let slotTop = frame.minY - (Self.pitch - Self.rowHeight) / 2
        let point = CGPoint(x: pointerX, y: slotTop + Self.pitch * fraction)
        return sidebarDropCandidate(at: point, layout: layout, frames: frames, visible: Self.visible, retaining: retaining)
    }

    func target(
        _ layout: SidebarDragLayout,
        at name: String,
        _ fraction: CGFloat,
        pointerX: CGFloat = 150,
        retaining: SidebarDropTarget? = nil
    ) -> SidebarDropTarget? {
        candidate(layout, at: name, fraction, pointerX: pointerX, retaining: retaining)?.target
    }

    func target(_ layout: SidebarDragLayout, at item: SidebarItem, _ fraction: CGFloat, projects: [Project]? = nil) -> SidebarDropTarget? {
        candidate(layout, at: item, fraction, projects: projects)?.target
    }
}
