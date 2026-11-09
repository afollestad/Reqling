import CoreGraphics
import ReqlingKit
import XCTest

@testable import Reqling

/// A sidebar drag from start to drop, driven as the row's gesture and the event monitor drive it, against the real
/// model. Rows are framed as the list lays them out (`SidebarDragTargetingTests`).
@MainActor
final class SidebarDragControllerTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var drag: SidebarDragController!
    private var project: ProjectID!
    private var ids: [String: RequestNodeID] = [:]

    override func setUp() async throws {
        fixture = AppFixture()
        let gate = SleepGate()
        self.gate = gate
        drag = SidebarDragController(model: fixture.model, system: SidebarDragSystem(
            sleep: { _ in await gate.sleep() },
            isEscapePressed: { false },
            isPointerDown: { true }
        ))
        project = try makeProject("API", nodes: [
            .request(RequestItem(name: "A", kind: .http(HTTPRequestSpec()))),
            .folder(RequestFolder(name: "F", children: [.request(RequestItem(name: "X", kind: .http(HTTPRequestSpec())))])),
            .request(RequestItem(name: "B", kind: .http(HTTPRequestSpec())))
        ])
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    func testADropMovesTheItemWhereTheLineShowed() throws {
        start("B")
        point(at: "A", 0.3)

        XCTAssertNotNil(drag.candidate?.line)
        XCTAssertTrue(drag.isDragged(item("B")))

        drag.sourceEnded(item("B"))

        XCTAssertEqual(names(), ["B", "A", "F"])
        XCTAssertTrue(drag.isIdle)
        XCTAssertNil(drag.candidate)
    }

    /// Escape drops the target and holds the drag until the mouse comes up, which then commits nothing.
    func testEscapeCancelsUntilTheMouseComesUp() {
        start("B")
        point(at: "A", 0.3)

        drag.escape()

        XCTAssertNil(drag.candidate)
        XCTAssertFalse(drag.isIdle, "The release still has to come")
        XCTAssertFalse(drag.isSourceEnabled(item("B")))

        drag.sourceEnded(item("B"))

        XCTAssertTrue(drag.isIdle)
        XCTAssertEqual(names(), ["A", "F", "B"])
    }

    /// The monitor freezes the drop at the mouse-up it sees; a row scrolled away, its gesture gone, still finishes.
    func testTheMouseUpFinishesADragWhoseRowNeverEnds() async {
        start("B")
        point(at: "A", 0.3)

        drag.monitorMouseUp(at: location(at: "A", 0.3))
        await waitUntil("the drag finishes") { self.drag.isIdle }

        XCTAssertEqual(names(), ["B", "A", "F"])
    }

    /// The drop the mouse-up froze is the one that lands, whatever the pointer reported after it.
    func testTheDropFrozenAtMouseUpIsTheOneCommitted() {
        start("B")
        point(at: "A", 0.3)
        drag.monitorMouseUp(at: location(at: "A", 0.3))

        drag.monitorMoved(to: location(at: "A", 0.7))
        drag.sourceEnded(item("B"))

        XCTAssertEqual(names(), ["B", "A", "F"])
    }

    /// A closed folder the pointer rests on opens after the pause, unless the pointer moved on first.
    func testAClosedFolderOpensOnlyOnceThePointerRestsOnIt() async {
        start("B")
        point(at: "F", 0.5)
        XCTAssertEqual(drag.candidate?.target, .into(item("F")))
        await waitUntil("the pause starts") { self.gate.pendingCount == 1 }

        point(at: "A", 0.3)
        gate.releaseAll()
        await waitUntil("the pause ends") { self.gate.pendingCount == 0 }
        XCTAssertFalse(fixture.model.isExpanded(folder: ids["F"]!, in: project))

        point(at: "F", 0.5)
        await waitUntil("the pause starts again") { self.gate.pendingCount == 1 }
        gate.releaseAll()
        await waitUntil("the folder opens") { self.fixture.model.isExpanded(folder: self.ids["F"]!, in: self.project) }
    }

    func testADropIntoAFolderPutsTheItemFirstAndOpensIt() {
        start("B")
        point(at: "F", 0.5)
        drag.sourceEnded(item("B"))

        let folder = fixture.library.document(project)?.folder(ids["F"]!)
        XCTAssertEqual(folder?.children.map(\.name), ["B", "X"])
        XCTAssertTrue(fixture.model.isExpanded(folder: ids["F"]!, in: project))
    }

    /// Into another project, the drop asks first.
    func testADropIntoAnotherProjectAsksFirst() throws {
        let other = try makeProject("Web", nodes: [])
        start("B")
        drag.monitorMoved(to: location(at: .project(other), 0.5))
        drag.sourceEnded(item("B"))

        XCTAssertEqual(fixture.model.movePending?.request.destination, other)
        XCTAssertEqual(names(), ["A", "F", "B"])
    }

    func testAProjectDropsBetweenTheOthers() throws {
        let other = try makeProject("Web", nodes: [])
        drag.geometryChanged(geometry())
        drag.sourceChanged(.project(other))
        drag.monitorMoved(to: location(at: .project(project), 0.3))
        drag.sourceEnded(.project(other))

        XCTAssertEqual(fixture.library.projects.map(\.id), [other, project])
    }

    func testNothingDragsWhileTheSidebarIsFiltered() {
        fixture.model.sidebar.query = "A"
        drag.geometryChanged(geometry())
        drag.sourceChanged(item("B"))

        XCTAssertTrue(drag.isIdle)
    }

    /// An agent deleting the dragged item mid-drag ends the drag rather than leaving one for nothing.
    func testTheDragEndsWhenTheDraggedItemGoes() {
        start("B")
        fixture.model.delete(ids["B"]!, in: project)

        point(at: "A", 0.3)

        XCTAssertTrue(drag.isIdle)
    }

    func testAClickSelectsTheRowButNotDuringADrag() {
        drag.click(item("A"))
        XCTAssertEqual(fixture.model.selection, item("A"))

        start("B")
        drag.click(item("B"))
        XCTAssertEqual(fixture.model.selection, item("A"))
    }

    // MARK: - Helpers

    private func makeProject(_ name: String, nodes: [RequestNode]) throws -> ProjectID {
        let id = try fixture.library.createProject(named: name)
        try fixture.library.mutate(id) { $0.items = nodes }
        func record(_ nodes: [RequestNode]) {
            for node in nodes {
                ids[node.name] = node.id
                if case .folder(let folder) = node {
                    record(folder.children)
                }
            }
        }
        record(nodes)
        return id
    }

    private func item(_ name: String) -> SidebarItem {
        .node(project, ids[name] ?? RequestNodeID())
    }

    private func names() -> [String] {
        fixture.library.document(project)?.items.map(\.name) ?? []
    }

    private func start(_ name: String) {
        drag.geometryChanged(geometry())
        drag.sourceChanged(item(name))
        XCTAssertFalse(drag.isIdle, "The drag of \(name) started")
    }

    private func point(at name: String, _ fraction: CGFloat) {
        drag.monitorMoved(to: location(at: item(name), fraction))
    }

    private func location(at name: String, _ fraction: CGFloat) -> CGPoint {
        location(at: item(name), fraction)
    }

    /// `fraction` of the way down the row's 32pt slot.
    private func location(at item: SidebarItem, _ fraction: CGFloat) -> CGPoint {
        let frame = geometry().rows[item] ?? .zero
        return CGPoint(x: 150, y: frame.minY - 8 + 32 * fraction)
    }

    /// Every shown row, in the list's order, 32pt apart with 16pt content frames.
    private func geometry() -> SidebarDragGeometry {
        var rows: [SidebarItem: CGRect] = [:]
        var row = 0
        func add(_ item: SidebarItem, leading: CGFloat) {
            rows[item] = CGRect(x: leading, y: CGFloat(row) * 32 + 8, width: 250, height: 16)
            row += 1
        }
        func addNodes(_ nodes: [RequestNode], in project: ProjectID) {
            for node in nodes {
                add(.node(project, node.id), leading: 37)
                if case .folder(let folder) = node, fixture.model.isExpanded(folder: folder.id, in: project) {
                    addNodes(folder.children, in: project)
                }
            }
        }
        for section in fixture.model.sidebar.sections {
            add(.project(section.id), leading: 25)
            if fixture.model.isExpanded(section.id) {
                addNodes(section.items, in: section.id)
            }
        }
        let list = CGRect(x: 0, y: 0, width: 300, height: 2_000)
        return SidebarDragGeometry(rows: rows, list: list, visible: list)
    }
}
