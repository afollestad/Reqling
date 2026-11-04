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

    func testProjectSettingsRoundTripProtoDefinitionsThroughTheDocument() throws {
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        let protos = root.appendingPathComponent("protos", isDirectory: true)
        let external = fixture.profile.applicationSupportDirectory.appendingPathComponent("External protos", isDirectory: true)
        let descriptorSet = root.appendingPathComponent("schema/api.protoset")
        for directory in [protos, external, descriptorSet.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: descriptorSet)
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)

        fixture.system.directoryToChoose = protos
        settings.addProtoRoot()
        settings.addProtoRoot()
        fixture.system.directoryToChoose = external
        fixture.system.pathSharing = .thisMacOnly
        settings.addProtoRoot()
        settings.addEntryFile()
        settings.protoEntryFiles[0].path = "  acme/v1/users.proto "
        settings.addEntryFile()
        fixture.system.fileToChoose = descriptorSet
        settings.addDescriptorSet()

        XCTAssertEqual(settings.protoRoots.count, 2, "adding the same folder twice keeps one")
        XCTAssertEqual(settings.protoRoots.first, .relative("protos"))
        XCTAssertEqual(settings.protoRoots.map(settings.sharing(of:)), [.shared, .thisMacOnly])
        XCTAssertEqual(settings.descriptorSets, [.relative("schema/api.protoset")])
        XCTAssertTrue(settings.hasUnsavedProtoChanges)
        XCTAssertTrue(settings.save())

        let saved = try XCTUnwrap(fixture.library.document(project)?.grpc)
        XCTAssertEqual(saved, ProjectGRPCConfiguration(
            protoRoots: settings.protoRoots,
            protoFiles: ["acme/v1/users.proto"],
            descriptorSets: [.relative("schema/api.protoset")]
        ))
        XCTAssertEqual(fixture.model.pathResolver(for: project)?.url(for: saved.protoRoots[1])?.path, external.path)

        let reopened = ProjectSettingsModel(projectID: project, app: fixture.model)
        XCTAssertEqual(reopened.protoRoots, saved.protoRoots)
        XCTAssertEqual(reopened.protoEntryFiles.map(\.path), ["acme/v1/users.proto"])
        XCTAssertEqual(reopened.descriptorSets, saved.descriptorSets)
        XCTAssertFalse(reopened.hasUnsavedProtoChanges)
        XCTAssertNil(reopened.workspaceStatus)
        fixture.model.libraryDidChange()
        XCTAssertNotNil(reopened.workspaceStatus, "a saved configuration gets a workspace")

        reopened.removeProtoRoot(at: 1)
        reopened.removeEntryFile(reopened.protoEntryFiles[0].id)
        reopened.removeDescriptorSet(at: 0)
        XCTAssertTrue(reopened.save())
        XCTAssertEqual(fixture.library.document(project)?.grpc, ProjectGRPCConfiguration(protoRoots: [.relative("protos")]))
    }

    func testProjectSettingsPickingTheSameThisMacFolderOrFileAgainIsANoOp() throws {
        let external = fixture.profile.applicationSupportDirectory.appendingPathComponent("External protos", isDirectory: true)
        let descriptorSet = external.appendingPathComponent("api.protoset")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data().write(to: descriptorSet)
        fixture.system.pathSharing = .thisMacOnly
        fixture.system.directoryToChoose = external
        fixture.system.fileToChoose = descriptorSet
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)

        settings.addProtoRoot()
        settings.addProtoRoot()
        settings.addDescriptorSet()
        settings.addDescriptorSet()
        XCTAssertTrue(settings.save())
        let reopened = ProjectSettingsModel(projectID: project, app: fixture.model)
        reopened.addProtoRoot()
        reopened.addDescriptorSet()

        XCTAssertEqual(reopened.protoRoots.count, 1)
        XCTAssertEqual(reopened.descriptorSets.count, 1)
        XCTAssertEqual(fixture.component.workspaceState.state.localPaths.count, 2, "a repeat pick records no second local path")
    }

    func testProjectSettingsEntryFileEditsLandOnlyOnTheirOwnRow() {
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        settings.addEntryFile()
        settings.addEntryFile()
        let removed = settings.protoEntryFiles[0].id
        let kept = settings.protoEntryFiles[1].id

        settings.setEntryFilePath("kept.proto", for: kept)
        settings.removeEntryFile(removed)
        // A commit from the removed row arriving after it left must not overwrite the row now in its place.
        settings.setEntryFilePath("late.proto", for: removed)

        XCTAssertEqual(settings.protoEntryFiles.map(\.id), [kept])
        XCTAssertEqual(settings.protoEntryFiles.map(\.path), ["kept.proto"])
    }
}
