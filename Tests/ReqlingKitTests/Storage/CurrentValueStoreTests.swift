import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import Security
import XCTest

@MainActor
final class CurrentValueStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var secrets: InMemorySecretStore!
    private let project = ProjectID()
    private let staging = EnvironmentID()

    override func setUp() async throws {
        directory = try TemporaryDirectory()
        secrets = InMemorySecretStore()
    }

    override func tearDown() async throws {
        directory.remove()
    }

    private var url: URL {
        directory.file("current-values.json")
    }

    private func store(secretStore: (any SecretStore)? = nil) -> CurrentValueStore {
        CurrentValueStore(url: url, secretStore: secretStore ?? secrets)
    }

    func testValuesAndMarkersSurviveARelaunchWithSecretsOnlyInTheKeychain() throws {
        let store = store()
        store.apply([
            "userId": .value(TemplateVariable(value: "42")),
            "token": .value(TemplateVariable(value: "s3cr3t", isSecret: true)),
            "gone": .unset
        ], in: .environment(project, staging))
        store.apply(["region": .value(TemplateVariable(value: "eu"))], in: .global)

        let relaunched = self.store()
        let file = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(relaunched.values(in: .environment(project, staging)), [
            "userId": .value(TemplateVariable(value: "42")),
            "token": .value(TemplateVariable(value: "s3cr3t", isSecret: true)),
            "gone": .unset
        ])
        XCTAssertEqual(relaunched.values(in: .global), ["region": .value(TemplateVariable(value: "eu"))])
        XCTAssertFalse(file.contains("s3cr3t"))
        XCTAssertEqual(try secrets.secrets(for: project)[SecretKey.currentValue("token", in: staging)], "s3cr3t")
    }

    func testTheSnapshotCoversGlobalAndEachEnvironmentOfOneProject() {
        let store = store()
        let other = ProjectID()
        store.apply(["a": .value(TemplateVariable(value: "1"))], in: .environment(project, staging))
        store.apply(["b": .value(TemplateVariable(value: "2"))], in: .environment(other, staging))
        store.apply(["c": .unset], in: .global)

        let snapshot = store.snapshot(for: project)

        XCTAssertEqual(snapshot.global, ["c": .unset])
        XCTAssertEqual(snapshot.environments, [staging: ["a": .value(TemplateVariable(value: "1"))]])
    }

    func testResettingDropsValuesAndTheirKeychainEntries() throws {
        let store = store()
        let scope = CurrentValueScope.environment(project, staging)
        store.apply([
            "token": .value(TemplateVariable(value: "s3cr3t", isSecret: true)),
            "keep": .value(TemplateVariable(value: "1")),
            "also": .value(TemplateVariable(value: "2"))
        ], in: scope)
        let revision = store.revision

        store.reset(["token", "missing"], in: scope)

        XCTAssertEqual(Set(store.values(in: scope).keys), ["keep", "also"])
        XCTAssertNil(try secrets.secrets(for: project)[SecretKey.currentValue("token", in: staging)])
        XCTAssertGreaterThan(store.revision, revision)

        store.reset(in: scope)

        XCTAssertTrue(store.values(in: scope).isEmpty)
        XCTAssertFalse(store.hasValues(for: project))
    }

    func testReplacingASecretWithAMarkerDeletesTheStoredSecret() throws {
        let store = store()
        let scope = CurrentValueScope.global
        store.apply(["token": .value(TemplateVariable(value: "s3cr3t", isSecret: true))], in: scope)

        store.apply(["token": .unset], in: scope)

        XCTAssertEqual(store.values(in: scope), ["token": .unset])
        XCTAssertTrue(try secrets.secrets(for: .global).isEmpty)
    }

    func testForgettingAProjectDropsOnlyItsValues() {
        let store = store()
        store.apply(["a": .value(TemplateVariable(value: "1"))], in: .environment(project, staging))
        store.apply(["b": .value(TemplateVariable(value: "2"))], in: .global)

        store.forget(project)

        XCTAssertTrue(store.snapshot(for: project).environments.isEmpty)
        XCTAssertEqual(self.store().values(in: .global).count, 1)
    }

    /// A Keychain that refuses the read leaves secrets out, so a run falls back to the saved value, and says why.
    func testAnUnreadableKeychainLeavesSecretsOutAndReportsIt() {
        let store = store()
        store.apply([
            "token": .value(TemplateVariable(value: "s3cr3t", isSecret: true)),
            "plain": .value(TemplateVariable(value: "1"))
        ], in: .global)
        secrets.isFailingReads = true

        let values = store.values(in: .global)

        XCTAssertEqual(values, ["plain": .value(TemplateVariable(value: "1"))])
        XCTAssertEqual(store.issue, CurrentValueStore.unreadableMessage)
    }

    func testASecretTheKeychainRefusesToStoreLastsForTheSession() {
        let refusing = RefusingSecretStore()
        let store = store(secretStore: refusing)

        store.apply(["token": .value(TemplateVariable(value: "s3cr3t", isSecret: true))], in: .global)

        XCTAssertEqual(store.values(in: .global), ["token": .value(TemplateVariable(value: "s3cr3t", isSecret: true))])
        XCTAssertEqual(store.issue, CurrentValueStore.unwritableMessage)
        XCTAssertTrue(self.store(secretStore: refusing).values(in: .global).isEmpty, "A relaunch can't recover a value that was never stored")
    }

    func testAnUndecodableFileIsSetAsideAndStartsEmpty() throws {
        try Data("not json".utf8).write(to: url)

        let store = store()

        XCTAssertTrue(store.values(in: .global).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("current-values.corrupt-") })
    }
}

/// Reads succeed with nothing stored; every write fails, as a locked Keychain does.
private final class RefusingSecretStore: SecretStore {
    func secrets(for account: SecretAccount) throws -> [String: String] {
        [:]
    }

    func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws {
        throw SecretStoreError.keychain(errSecAuthFailed)
    }
}
