import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class SheetModelTests: XCTestCase {
    var fixture: AppFixture!
    var project: ProjectID!

    override func setUp() async throws {
        fixture = AppFixture()
        fixture.model.createProject(named: "Sheets")
        project = fixture.model.selection?.projectID
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    func testEnvironmentsKeepGlobalAndDefaultFirstAndSaveWithSecretsInTheStore() throws {
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.removeEnvironment(editor.globalEnvironment.id)
        editor.removeEnvironment(editor.defaultEnvironment.id)
        XCTAssertEqual(editor.allEnvironments.map(\.name), ["Global", "Default"])

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

    func testEnvironmentsDoneMergesWithChangesMadeElsewhereWhileTheSheetWasOpen() throws {
        let both = Variable(key: "both", value: "1")
        let elsewhere = Variable(key: "elsewhere", value: "1")
        let removed = Variable(key: "removed", value: "1")
        let secret = Variable(key: "token", value: "s3cr3t", isSecret: true)
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "host", value: "a")])
        let gone = RequestEnvironment(name: "Gone")
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [both, elsewhere, removed, secret]
            document.environments = [staging, gone]
        }
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.defaultEnvironment.variables[0].value = "sheet"
        editor.addEnvironment()

        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables[0].value = "agent"
            document.defaultEnvironment.variables[1].value = "agent"
            document.defaultEnvironment.variables.removeAll { $0.id == removed.id }
            document.environments[0].name = "Staging (renamed)"
            document.environments.removeAll { $0.id == gone.id }
            document.environments.append(RequestEnvironment(name: "Added elsewhere"))
        }
        XCTAssertTrue(editor.save())

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.defaultEnvironment.variables.map(\.key), ["both", "elsewhere", "token"], "a removal elsewhere stays")
        XCTAssertEqual(document.defaultEnvironment.variables.map(\.value), ["sheet", "agent", "s3cr3t"])
        XCTAssertEqual(document.environments.map(\.name), ["Staging (renamed)", "New Environment", "Added elsewhere"])
        XCTAssertEqual(try fixture.component.secretStore.secrets(for: project).values.sorted(), ["s3cr3t"])
        XCTAssertEqual(editor.environments.map(\.name), document.environments.map(\.name), "the sheet shows what Done stored")
    }

    /// A value the sheet typed in the clear stays out of the file when the variable was made secret elsewhere meanwhile.
    func testAVariableMadeSecretElsewhereStaysSecretWhenTheSheetEditsIt() throws {
        let variable = Variable(key: "token", value: "old")
        try fixture.library.mutate(project) { $0.defaultEnvironment.variables = [variable] }
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.defaultEnvironment.variables[0].value = "typed"
        try fixture.library.mutate(project) { $0.defaultEnvironment.variables[0].isSecret = true }

        XCTAssertTrue(editor.save())

        let saved = try XCTUnwrap(fixture.library.document(project)?.defaultEnvironment.variables.first)
        XCTAssertTrue(saved.isSecret)
        XCTAssertEqual(saved.value, "typed")
        let file = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("environments/default.json"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("typed"))
    }

    func testGlobalSavesForEveryProjectAndNeverBecomesActive() throws {
        fixture.model.createProject(named: "Other")
        let other = try XCTUnwrap(fixture.model.selection?.projectID)
        let active = fixture.model.activeEnvironmentID(for: project)
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = editor.globalEnvironment.id
        XCTAssertFalse(editor.canRemoveSelected)
        editor.selected.name = "Renamed"
        editor.selected.variables = [Variable(key: "region", value: "eu"), Variable(key: "token", value: "g10bal", isSecret: true)]

        XCTAssertTrue(editor.save())

        XCTAssertEqual(fixture.library.globalEnvironment.name, "Global")
        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.value), ["eu", "g10bal"])
        XCTAssertEqual(fixture.model.activeEnvironmentID(for: project), active)
        XCTAssertEqual(try fixture.component.secretStore.secrets(for: .global).values.sorted(), ["g10bal"])
        XCTAssertTrue(try fixture.component.secretStore.secrets(for: project).isEmpty)
        XCTAssertEqual(EnvironmentEditorModel(projectID: other, app: fixture.model).globalEnvironment.variables.map(\.key), ["region", "token"])
        XCTAssertEqual(fixture.model.scope(for: other).lookup("region")?.value, "eu")
    }

    func testGlobalDoneMergesWithChangesMadeElsewhereWhileTheSheetWasOpen() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "a", value: "1"), Variable(key: "b", value: "1")] }
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.globalEnvironment.variables[0].value = "sheet"

        try fixture.library.mutateGlobalEnvironment { $0.variables[1].value = "agent" }
        XCTAssertTrue(editor.save())

        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.value), ["sheet", "agent"])
        XCTAssertEqual(editor.globalEnvironment, fixture.library.globalEnvironment, "the sheet shows what Done stored")
    }

    func testDoneSavesGlobalFromAReadOnlyProjectsSheet() throws {
        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: projectFile)) as? [String: Any])
        json["formatVersion"] = ProjectDocument.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: projectFile)
        fixture.library.reload(project)
        XCTAssertEqual(fixture.library.project(project)?.isReadOnly, true)
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.globalEnvironment.variables = [Variable(key: "region", value: "eu")]

        XCTAssertTrue(editor.save())

        XCTAssertNil(fixture.model.alert)
        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.key), ["region"])
    }

    func testOpeningEnvironmentsReadsSecretsTheKeychainCouldNotGiveAtLaunch() throws {
        let keychain = LockableSecretStore()
        let launched = AppFixture(secretStore: keychain)
        defer { launched.tearDown() }
        launched.model.createProject(named: "Locked")
        let project = try XCTUnwrap(launched.model.selection?.projectID)
        try launched.library.mutate(project) { $0.defaultEnvironment.variables = [Variable(key: "token", value: "project", isSecret: true)] }
        try launched.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "key", value: "global", isSecret: true)] }
        keychain.isLocked = true
        let relaunched = AppFixture(profile: launched.profile, secretStore: keychain)
        defer { relaunched.tearDown() }
        keychain.isLocked = false

        relaunched.model.sheet = .environments(project)
        let editor = EnvironmentEditorModel(projectID: project, app: relaunched.model)

        XCTAssertEqual(editor.globalEnvironment.variables.map(\.value), ["global"])
        XCTAssertEqual(editor.defaultEnvironment.variables.map(\.value), ["project"])
        XCTAssertNil(editor.globalEnvironmentIssue)
        XCTAssertEqual(relaunched.library.project(project)?.issues, [])
    }

    func testDoneRefusesAProjectEnvironmentNamedLikeGlobal() throws {
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.addEnvironment()
        editor.selected.name = " global "

        XCTAssertNotNil(editor.reservedNameProblem)
        XCTAssertFalse(editor.save())
        XCTAssertTrue(try XCTUnwrap(fixture.library.document(project)).environments.isEmpty, "nothing was saved")

        editor.selected.name = "Global Staging"
        XCTAssertNil(editor.reservedNameProblem)
        XCTAssertTrue(editor.save())
        XCTAssertEqual(try XCTUnwrap(fixture.library.document(project)).environments.map(\.name), ["Global Staging"])
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

    func testProjectSettingsDoneMergesWithChangesMadeElsewhereWhileTheSheetWasOpen() throws {
        let typed = ClientCertificateEntry(hostPattern: "a.test", source: .pkcs12(.relative("a.p12")))
        let untouched = ClientCertificateEntry(hostPattern: "b.test", source: .pkcs12(.relative("b.p12")))
        try fixture.library.mutate(project) { document in
            document.tls.clientCertificates = [typed, untouched]
            document.tls.caCertificates = [.relative("ca.pem")]
        }
        try fixture.library.setCertificatePassphrase("untouched", for: untouched.id, in: project)
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        settings.name = "Renamed here"
        settings.passphrases[typed.id] = "typed"

        let added = ClientCertificateEntry(hostPattern: "c.test", source: .pkcs12(.relative("c.p12")))
        try fixture.library.mutate(project) { document in
            // The sheet changed `typed`'s passphrase, so its edit beats this removal; it never touched `untouched`.
            document.tls.clientCertificates = [added]
            document.tls.caCertificates.append(.relative("other.pem"))
            document.auth = .bearer(token: "{{agent}}")
        }
        try fixture.library.setCertificatePassphrase("added", for: added.id, in: project)
        XCTAssertTrue(settings.save())

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.name, "Renamed here")
        XCTAssertEqual(document.auth, .bearer(token: "{{agent}}"))
        XCTAssertEqual(document.tls.clientCertificates, [typed, added])
        XCTAssertEqual(document.tls.caCertificates, [.relative("ca.pem"), .relative("other.pem")])
        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: typed.id, in: project), "typed")
        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: added.id, in: project), "added")
        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: untouched.id, in: project), "untouched", "not the sheet's removal")
        XCTAssertEqual(settings.passphrases[added.id], "added", "the sheet shows what Done stored")
    }

    func testAPassphraseTheKeychainCannotReadIsFlaggedAndNeverSavedOver() async throws {
        let entry = ClientCertificateEntry(hostPattern: "a.test", source: .pkcs12(.relative("a.p12")))
        try fixture.library.mutate(project) { $0.tls.clientCertificates = [entry] }
        try fixture.library.setCertificatePassphrase("hunter2", for: entry.id, in: project)
        let store = try XCTUnwrap(fixture.component.secretStore as? InMemorySecretStore)
        store.isFailingReads = true
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        store.isFailingReads = false

        XCTAssertEqual(settings.unreadablePassphrases, [entry.id])
        let status = await settings.refreshStatus(of: entry)
        XCTAssertEqual(status, .problem("Reqling couldn't read this certificate's passphrase from the Keychain."))
        settings.name = "Renamed"
        XCTAssertTrue(settings.save())
        XCTAssertEqual(try fixture.library.loadCertificatePassphrase(for: entry.id, in: project), "hunter2")
    }

    func testACertificateFileIsPKCS12OrAPEMCertificateWithItsKey() throws {
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        let combined = "-----BEGIN CERTIFICATE-----\nMII=\n-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\nMII=\n-----END PRIVATE KEY-----\n"
        try Data("-----BEGIN CERTIFICATE-----\nMII=\n-----END CERTIFICATE-----\n".utf8).write(to: root.appendingPathComponent("client.crt"))
        try Data(combined.utf8).write(to: root.appendingPathComponent("combined.pem"))
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)

        fixture.system.filesToChoose = [root.appendingPathComponent("client.p12")]
        settings.addCertificateFile()
        fixture.system.filesToChoose = [root.appendingPathComponent("client.crt"), nil]
        settings.addCertificateFile()
        XCTAssertEqual(settings.clientCertificates.map(\.source), [.pkcs12(.relative("client.p12"))], "cancelling the key adds nothing")

        fixture.system.filesToChoose = [root.appendingPathComponent("client.crt"), root.appendingPathComponent("client.key")]
        settings.addCertificateFile()
        fixture.system.filesToChoose = [root.appendingPathComponent("combined.pem")]
        settings.addCertificateFile()

        XCTAssertEqual(settings.clientCertificates.dropFirst().map(\.source), [
            .pem(certificate: .relative("client.crt"), key: .relative("client.key")),
            .pem(certificate: .relative("combined.pem"), key: .relative("combined.pem"))
        ])
        XCTAssertEqual(fixture.system.fileMessages, [
            nil,
            nil, "Choose the private key for client.crt.",
            nil, "Choose the private key for client.crt.",
            nil
        ], "a file holding its key asks for no other")
    }

    func testAnUnreadablePEMKeyPassphraseIsFlaggedLikeAPKCS12One() async throws {
        let entry = ClientCertificateEntry(hostPattern: "a.test", source: .pem(certificate: .relative("a.crt"), key: .relative("a.key")))
        try fixture.library.mutate(project) { $0.tls.clientCertificates = [entry] }
        try fixture.library.setCertificatePassphrase("hunter2", for: entry.id, in: project)
        let store = try XCTUnwrap(fixture.component.secretStore as? InMemorySecretStore)
        store.isFailingReads = true
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        store.isFailingReads = false

        let status = await settings.refreshStatus(of: entry)
        XCTAssertEqual(status, .problem("Reqling couldn't read this certificate's passphrase from the Keychain."))
    }

    func testAMissingCertificateFileIsReportedAsAProblem() async {
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        let entry = ClientCertificateEntry(hostPattern: "api.test", source: .pkcs12(.relative("missing.p12")))

        let status = await settings.refreshStatus(of: entry)
        XCTAssertEqual(status, .problem(TLSError.missingFile("“missing.p12”").localizedDescription))
        XCTAssertTrue(settings.isValidHostPattern("*.api.test:8443"))
        XCTAssertFalse(settings.isValidHostPattern("https://api.test"))
    }

    /// The test graph has no helper, so the check fails closed; what matters is that the file reached the probe.
    func testAPKCS12FileIsCheckedBeforeItOpensAndItsStatusKeptUntilRemoved() async throws {
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try Data("not a PKCS#12 file".utf8).write(to: root.appendingPathComponent("client.p12"))
        let entry = ClientCertificateEntry(hostPattern: "api.test", source: .pkcs12(.relative("client.p12")))
        try fixture.library.mutate(project) { $0.tls.clientCertificates = [entry] }
        let settings = ProjectSettingsModel(projectID: project, app: fixture.model)
        XCTAssertNil(settings.certificateStatuses[entry.id])

        await settings.refreshStatus(of: entry)
        let missing = TLSError.certificateCheckFailed("Reqling's certificate checker is missing. Reinstall Reqling.")
        XCTAssertEqual(settings.certificateStatuses[entry.id], .problem(missing.localizedDescription))

        settings.removeClientCertificate(entry.id)
        XCTAssertNil(settings.certificateStatuses[entry.id])
        await settings.refreshStatus(of: entry)
        XCTAssertNil(settings.certificateStatuses[entry.id], "a check finishing after its entry went keeps nothing")
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
        XCTAssertEqual(fixture.component.workspaceState.localPaths(in: project).count, 2, "a repeat pick records no second local path")
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
