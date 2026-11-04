import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class SheetModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: ProjectID!

    override func setUp() async throws {
        fixture = AppFixture()
        fixture.model.createProject(named: "Sheets")
        project = fixture.model.selection?.projectID
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    func testEnvironmentsKeepDefaultFirstAndSaveWithSecretsInTheStore() throws {
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.removeEnvironment(editor.defaultEnvironment.id)
        XCTAssertEqual(editor.allEnvironments.count, 1)

        editor.addEnvironment()
        editor.addEnvironment()
        XCTAssertEqual(editor.environments.map(\.name), ["New Environment", "New Environment 2"])
        editor.selected.variables = [Variable(key: "token", value: "s3cr3t", isSecret: true)]

        XCTAssertTrue(editor.save())

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.allEnvironments.map(\.name), ["Default", "New Environment", "New Environment 2"])
        XCTAssertEqual(fixture.model.activeEnvironmentID(for: project), editor.selectedID)
        let file = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("environments/new-environment-2.json"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("s3cr3t"))
        XCTAssertEqual(document.environment(editor.selectedID)?.variables.first?.value, "s3cr3t")
    }

    func testDuplicateKeysAreReported() {
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selected.variables = [Variable(key: "a", value: "1"), Variable(key: "a", value: "2"), Variable(key: "b", value: "3")]

        XCTAssertEqual(editor.duplicateKeys, ["a"])
    }

    func testProjectSettingsSaveNameAuthAndCertificatesWithPassphrasesOutOfFiles() throws {
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        settings.name = "Renamed"
        settings.auth = .bearer(token: "{{token}}")
        let entry = ClientCertificateEntry(hostPattern: "*.internal", source: .pkcs12(.relative("client.p12")))
        settings.clientCertificates = [entry]
        settings.passphrases[entry.id] = "hunter2"

        XCTAssertTrue(settings.save())

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.name, "Renamed")
        XCTAssertEqual(document.auth, .bearer(token: "{{token}}"))
        XCTAssertEqual(document.tls.clientCertificates, [entry])
        XCTAssertEqual(fixture.library.certificatePassphrase(for: entry.id, in: project), "hunter2")
        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        XCTAssertFalse(try String(contentsOf: projectFile, encoding: .utf8).contains("hunter2"))
    }

    func testProjectSettingsSaveOnlyChangedPassphrasesAndForgetRemovedEntries() throws {
        let kept = ClientCertificateEntry(hostPattern: "a.test", source: .pkcs12(.relative("a.p12")))
        let removed = ClientCertificateEntry(hostPattern: "b.test", source: .keychainIdentity)
        try fixture.library.mutate(project) { $0.tls.clientCertificates = [kept, removed] }
        try fixture.library.setCertificatePassphrase("first", for: kept.id, in: project)
        try fixture.library.setCertificatePassphrase("second", for: removed.id, in: project)
        fixture.component.workspaceState.setKeychainIdentity(Data([1]), for: removed.id)
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        // Changed after the sheet loaded it: a field the user never touched must not save its stale copy back.
        try fixture.library.setCertificatePassphrase("rotated", for: kept.id, in: project)

        settings.removeClientCertificate(removed.id)
        XCTAssertTrue(settings.save())

        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: kept.id, in: project), "rotated")
        XCTAssertNil(try fixture.library.loadCertificatePassphrase(for: removed.id, in: project))
        XCTAssertNil(fixture.component.workspaceState.keychainIdentity(for: removed.id))
    }

    func testAPassphraseTheKeychainCannotReadIsFlaggedAndNeverSavedOver() throws {
        let entry = ClientCertificateEntry(hostPattern: "a.test", source: .pkcs12(.relative("a.p12")))
        try fixture.library.mutate(project) { $0.tls.clientCertificates = [entry] }
        try fixture.library.setCertificatePassphrase("hunter2", for: entry.id, in: project)
        let store = try XCTUnwrap(fixture.component.secretStore as? InMemorySecretStore)
        store.isFailingReads = true
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        store.isFailingReads = false

        XCTAssertEqual(settings.unreadablePassphrases, [entry.id])
        XCTAssertEqual(settings.status(of: entry), .problem("Reqling couldn't read this certificate's passphrase from the Keychain."))
        settings.name = "Renamed"
        XCTAssertTrue(settings.save())
        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: entry.id, in: project), "hunter2")
    }

    func testAMissingCertificateFileIsReportedAsAProblem() {
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        let entry = ClientCertificateEntry(hostPattern: "api.test", source: .pkcs12(.relative("missing.p12")))

        XCTAssertEqual(settings.status(of: entry), .problem(TLSError.missingFile("“missing.p12”").localizedDescription))
        XCTAssertTrue(settings.isValidHostPattern("*.api.test:8443"))
        XCTAssertFalse(settings.isValidHostPattern("https://api.test"))
    }
}
