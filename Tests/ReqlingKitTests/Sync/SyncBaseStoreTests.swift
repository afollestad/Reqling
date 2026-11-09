import CryptoKit
import Foundation
@testable import ReqlingKit
import XCTest

@MainActor
final class SyncBaseStoreTests: XCTestCase {
    /// Damage to one part of the state, such as the bases, loses only that part, never which projects are held back.
    func testADamagedFieldLosesOnlyItself() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let key = SymmetricKey(size: .bits256)
        let excluded = ProjectID()
        let store = SyncBaseStore(directory: directory.url, account: "account", key: key)
        store.update { state in
            state.excluded = [excluded]
            state.bases["project-x/record"] = SyncBaseStore.Base(fingerprint: "f", tree: OrderedJSONCodable(.null), secrets: [:])
        }
        store.save()

        let url = store.directory.appendingPathComponent("state.json")
        var state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        state["bases"] = "damaged"
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let reopened = SyncBaseStore(directory: directory.url, account: "account", key: key)

        XCTAssertEqual(reopened.state.excluded, [excluded])
        XCTAssertTrue(reopened.state.bases.isEmpty)
    }
}
