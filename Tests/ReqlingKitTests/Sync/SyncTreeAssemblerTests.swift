import Foundation
@testable import ReqlingKit
import XCTest

/// Every Mac that applies the same records must build the same tree, so the repairs are deterministic.
final class SyncTreeAssemblerTests: XCTestCase {
    private func ids(_ count: Int) -> [RequestNodeID] {
        (0..<count).map { _ in RequestNodeID() }.sorted { $0.description < $1.description }
    }

    private func assemble(_ assembler: SyncTreeAssembler, maxDepth: Int = 64) throws -> [String] {
        var assembler = assembler
        let nodes = try assembler.assemble(maxDepth: maxDepth) { id, children in
            .folder(RequestFolder(id: id, name: id.description, children: children))
        }
        func describe(_ nodes: [RequestNode], indent: String) -> [String] {
            nodes.flatMap { node -> [String] in
                guard case .folder(let folder) = node else {
                    return []
                }
                return [indent + folder.id.description] + describe(folder.children, indent: indent + "  ")
            }
        }
        return describe(nodes, indent: "")
    }

    func testChildrenFollowTheirParentsOrderThenAnyItDoesntListByID() throws {
        let id = ids(4)
        let tree = SyncTreeAssembler(
            folders: [id[0]: (nil, [id[3], id[1]]), id[1]: (id[0], []), id[2]: (id[0], []), id[3]: (id[0], [])],
            requests: [:],
            rootOrder: [id[0]]
        )

        XCTAssertEqual(try assemble(tree), [id[0], id[3], id[1], id[2]].enumerated().map { ($0 == 0 ? "" : "  ") + $1.description })
    }

    func testAnItemWhoseFolderIsGoneMovesToTheTopLevel() throws {
        let id = ids(2)
        let tree = SyncTreeAssembler(folders: [id[0]: (nil, []), id[1]: (RequestNodeID(), [])], requests: [:], rootOrder: [id[0]])

        XCTAssertEqual(try assemble(tree), [id[0].description, id[1].description])
    }

    /// Two Macs each moved one folder into the other: the cycle is broken at its lowest ID, on every Mac alike.
    func testACycleIsBrokenAtItsLowestID() throws {
        let id = ids(3)
        let tree = SyncTreeAssembler(
            folders: [id[0]: (id[1], []), id[1]: (id[0], []), id[2]: (id[1], [])],
            requests: [:],
            rootOrder: []
        )

        XCTAssertEqual(try assemble(tree), [id[0].description, "  " + id[1].description, "    " + id[2].description])
    }

    func testNestingBeyondTheLimitIsRefused() throws {
        let id = ids(4)
        let tree = SyncTreeAssembler(
            folders: [id[0]: (nil, []), id[1]: (id[0], []), id[2]: (id[1], []), id[3]: (id[2], [])],
            requests: [:],
            rootOrder: []
        )

        XCTAssertThrowsError(try assemble(tree, maxDepth: 2))
    }
}
