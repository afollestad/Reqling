import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

@MainActor
extension CurrentValueStoreTests {
    /// Whichever Mac wrote last, a secret current value never comes back as plain text for the same key, and a marker
    /// whose value didn't come along keeps the value this Mac holds.
    func testApplyingSyncedValuesNeverTurnsASecretPlain() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let store = CurrentValueStore(url: directory.file("current-values.json"), secretStore: secrets)
        store.apply([
            "token": .value(TemplateVariable(value: "t", isSecret: true)),
            "kept": .value(TemplateVariable(value: "k", isSecret: true))
        ], in: .global)
        var notified = 0
        store.onChange = { notified += 1 }

        store.applySynced(["token": .plain("leaked"), "kept": .secret, "added": .plain("a")], secrets: [:], in: .global)

        let values = store.values(in: .global)
        XCTAssertEqual(values["token"], .value(TemplateVariable(value: "leaked", isSecret: true)))
        XCTAssertEqual(values["kept"], .value(TemplateVariable(value: "k", isSecret: true)))
        XCTAssertEqual(values["added"], .value(TemplateVariable(value: "a")))
        XCTAssertFalse(try String(contentsOf: directory.file("current-values.json"), encoding: .utf8).contains("leaked"))
        XCTAssertEqual(notified, 0)
    }
}
