import Foundation
import ReqlingKit
import XCTest

@MainActor
final class WorkspaceStateStoreTests: XCTestCase {
    func testAnUndecodableStateFileIsBackedUpBeforeBeingReplaced() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.file("workspace.json")
        try "{ broken".write(to: file, atomically: true, encoding: .utf8)

        let store = WorkspaceStateStore(fileURL: file)
        store.setLocalPath("/Users/me/cert.p12", for: LocalPathID())

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasPrefix("workspace.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.file(backups[0]), encoding: .utf8), "{ broken")
        XCTAssertEqual(WorkspaceStateStore(fileURL: file).state, store.state)
    }
}
