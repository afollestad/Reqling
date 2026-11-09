import Foundation
import ReqlingKit
import ReqlingTemplating
import XCTest

@testable import Reqling

@MainActor
final class AppModelTests: XCTestCase {
    var fixture: AppFixture!
    private var gate: SleepGate!

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    var model: AppModel {
        fixture.model
    }

    func makeProject() throws -> ProjectID {
        model.createProject(named: "API")
        return try XCTUnwrap(model.selection?.projectID)
    }

    /// A second `AppModel` over the same storage, as a relaunch would build.
    func relaunch() -> AppModel {
        AppModel(
            library: fixture.library,
            workspace: fixture.component.workspaceState,
            runner: fixture.component.requestRunner,
            batches: fixture.component.batchRunner,
            settings: fixture.component.settingsStore,
            appInfo: AppFixture.appInfo,
            keychain: fixture.component.keychainIdentities,
            pkcs12Probe: fixture.component.pkcs12ImportProbe,
            system: fixture.system,
            importFetcher: fixture.importFetcher,
            protoWorkspaces: fixture.component.protoWorkspaces,
            protocTooling: fixture.protoc.model,
            mcpServer: fixture.component.mcpServer,
            updates: fixture.component.appUpdates
        )
    }

    /// Only a load prunes: an edit removing a reference keeps its path for undo, and a duplicate sharing a path keeps it.
    func testALaunchDropsOnlyTheLocalPathsAProjectNoLongerUses() throws {
        let project = try makeProject()
        let workspace = fixture.component.workspaceState
        let root = workspace.addLocalPath("/protos/root", for: .protoRoots, in: project)
        let removed = workspace.addLocalPath("/protos/removed", for: .protoRoots, in: project)
        var spec = HTTPRequestSpec()
        let requestID = RequestNodeID()
        spec.body.binary.file = workspace.addLocalPath("/files/body.bin", for: .binaryBody(requestID), in: project)
        let request = RequestItem(id: requestID, name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { document in
            document.grpc.protoRoots = [root, removed]
            try document.insert(.request(request), into: nil)
        }
        model.duplicate(request.id, in: project)
        model.delete(request.id, in: project)
        try fixture.library.mutate(project) { $0.grpc.protoRoots = [root] }

        XCTAssertEqual(workspace.localPaths(in: project).count, 3)

        _ = relaunch()

        XCTAssertEqual(Set(workspace.localPaths(in: project).values), ["/protos/root", "/files/body.bin"])
    }

    func testDeletingAProjectForgetsItsLocalPathsButRemovingKeepsThem() throws {
        let project = try makeProject()
        let workspace = fixture.component.workspaceState
        _ = workspace.addLocalPath("/protos", for: .protoRoots, in: project)

        model.removeProject(project)

        XCTAssertEqual(workspace.localPaths(in: project).count, 1)

        let other = try makeProject()
        _ = workspace.addLocalPath("/protos", for: .protoRoots, in: other)
        model.deleteProject(other)

        XCTAssertTrue(workspace.localPaths(in: other).isEmpty)
    }

    func testCreatingAProjectSelectsIt() throws {
        let project = try makeProject()

        XCTAssertEqual(model.selection, .project(project))
        XCTAssertEqual(fixture.library.document(project)?.name, "API")
    }

    func testNewItemsGoBesideTheSelectionOrInsideASelectedFolder() throws {
        let project = try makeProject()
        model.newRequest()
        let first = try XCTUnwrap(model.selection?.nodeID)
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        let nested = try XCTUnwrap(model.selection?.nodeID)

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.items.map(\.id), [first, folder])
        XCTAssertEqual(document.folder(folder)?.children.map(\.id), [nested])
        XCTAssertTrue(model.isExpanded(folder: folder, in: project))
        XCTAssertNotNil(model.editor)
    }

    func testDeletingTheSelectionSelectsItsParent() throws {
        let project = try makeProject()
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        model.delete(request, in: project)

        XCTAssertEqual(model.selection, .node(project, folder))
        XCTAssertNil(fixture.library.document(project)?.node(request))
        XCTAssertNil(model.editor)
    }

    func testDuplicatingDeepCopiesWithFreshIDs() throws {
        let project = try makeProject()
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        model.selection = .node(project, folder)

        model.duplicate(folder, in: project)

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.items.map(\.name), ["New Folder", "New Folder Copy"])
        let copy = try XCTUnwrap(document.folder(document.items[1].id))
        XCTAssertNotEqual(copy.children.first?.id, document.folder(folder)?.children.first?.id)
        XCTAssertEqual(model.selection, .node(project, copy.id))
    }

    func testTheSelectionIsRestoredOnRelaunch() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        let relaunched = relaunch()

        XCTAssertEqual(relaunched.selection, .node(project, request))
        XCTAssertEqual(relaunched.editor?.requestID, request)
    }

    func testARestoredSelectionWhoseItemIsGoneFallsBackToItsProject() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        // Deleted while Reqling was closed: nothing re-validates the saved selection before the relaunch.
        try fixture.library.mutate(project) { try $0.removeNode(request) }

        let relaunched = relaunch()

        XCTAssertEqual(relaunched.selection, .project(project))
        XCTAssertNil(relaunched.editor)
    }

    func testTheEditorFollowsTheProjectWhenRequestIDsRepeatAcrossProjects() throws {
        let first = try makeProject()
        let shared = RequestItem(name: "Shared", kind: .http(HTTPRequestSpec(url: "https://first")))
        try fixture.library.mutate(first) { try $0.insert(.request(shared), into: nil) }
        let second = try fixture.library.createProject(named: "Copy")
        let copy = RequestItem(id: shared.id, name: "Shared", kind: .http(HTTPRequestSpec(url: "https://second")))
        try fixture.library.mutate(second) { try $0.insert(.request(copy), into: nil) }

        model.selection = .node(first, shared.id)
        model.selection = .node(second, shared.id)

        XCTAssertEqual(model.editor?.projectID, second)
        XCTAssertEqual(model.editor?.asHTTP?.spec.url, "https://second")
    }

    func testFileReferencesAreRelativeInsideTheProjectAndAskedForOutside() throws {
        let project = try makeProject()
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        let inside = root.appendingPathComponent("fixtures/body.bin")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).bin")
        let body = ProjectPathSlot.binaryBody(RequestNodeID())

        XCTAssertEqual(model.reference(for: inside, in: project, at: body), .relative("fixtures/body.bin"))

        fixture.system.pathSharing = .thisMacOnly
        guard case .local(let id) = model.reference(for: outside, in: project, at: body) else {
            return XCTFail("Expected a this-Mac-only reference")
        }
        XCTAssertEqual(fixture.component.workspaceState.localPath(id, in: project), outside.path)

        fixture.system.pathSharing = nil
        XCTAssertNil(model.reference(for: outside, in: project, at: body))

        fixture.system.pathSharing = .shared
        let shared = try XCTUnwrap(model.reference(for: outside, in: project, at: body))
        guard case .relative(let path) = shared else {
            return XCTFail("Expected a shared reference")
        }
        XCTAssertEqual(model.pathResolver(for: project)?.url(for: shared, in: body)?.lastPathComponent, outside.lastPathComponent)
        XCTAssertEqual(fixture.component.workspaceState.choices(in: project)[shared], [body])
        XCTAssertEqual(fixture.component.workspaceState.projectState(project).chosenOutsidePaths, [path])
    }

    func testAFolderCannotMoveIntoItselfOrItsDescendants() throws {
        let project = try makeProject()
        model.newFolder()
        let outer = try XCTUnwrap(model.selection?.nodeID)
        model.newFolder()
        let inner = try XCTUnwrap(model.selection?.nodeID)

        XCTAssertFalse(model.canMove(outer, in: project, into: outer))
        XCTAssertFalse(model.canMove(outer, in: project, into: inner))
        XCTAssertTrue(model.canMove(inner, in: project, into: nil))
    }

    func testDeletingAFolderMovesASelectionInsideItToTheFolderParent() throws {
        let project = try makeProject()
        model.newFolder()
        let outer = try XCTUnwrap(model.selection?.nodeID)
        model.newFolder()
        let inner = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        model.editor?.asHTTP?.spec.method = .post

        model.delete(inner, in: project)

        XCTAssertEqual(model.selection, .node(project, outer))
        XCTAssertNil(model.editor)
        XCTAssertNil(model.alert)
    }

    func testAnUnavailableProjectKeepsItsSelectionUntilItLeavesTheLibrary() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))

        fixture.library.reload(project)
        model.libraryDidChange()
        XCTAssertEqual(model.selection, .node(project, request))
        XCTAssertNotNil(model.editor)

        fixture.library.removeProject(project)
        model.libraryDidChange()
        XCTAssertNil(model.selection)
    }

    func testFolderAuthSavesAfterThePauseOrWhenTheSelectionMoves() async throws {
        let project = try makeProject()
        model.newFolder()
        let folderID = try XCTUnwrap(model.selection?.nodeID)
        let folder = try XCTUnwrap(fixture.library.document(project)?.folder(folderID))
        func storedAuth() -> HTTPAuth? {
            fixture.library.document(project)?.folder(folderID)?.auth
        }

        model.setAuth(.bearer(token: "a"), forFolder: folderID, in: project)
        model.setAuth(.bearer(token: "ab"), forFolder: folderID, in: project)
        XCTAssertEqual(storedAuth(), .inherit)
        XCTAssertEqual(model.folderAuth(folder, in: project), .bearer(token: "ab"))
        await waitUntil("the autosave to start waiting") { gate.pendingCount > 0 }
        gate.releaseAll()
        await waitUntil("the folder auth autosave") { storedAuth() == .bearer(token: "ab") }

        model.setAuth(.bearer(token: "abc"), forFolder: folderID, in: project)
        model.selection = .project(project)
        XCTAssertEqual(storedAuth(), .bearer(token: "abc"))
    }

    func testAFolderAuthEditStrandedByAnUnavailableProjectSaysItWasDiscarded() throws {
        let project = try makeProject()
        model.newFolder()
        let folderID = try XCTUnwrap(model.selection?.nodeID)
        model.setAuth(.bearer(token: "a"), forFolder: folderID, in: project)
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))
        fixture.library.reload(project)

        model.selection = .project(project)

        XCTAssertEqual(model.alert?.title, "Unsaved Changes Discarded")
    }

    func testQuittingAsksBeforeLosingAFolderAuthEditStrandedByAnUnavailableProject() throws {
        let project = try makeProject()
        model.newFolder()
        let folderID = try XCTUnwrap(model.selection?.nodeID)
        model.setAuth(.bearer(token: "a"), forFolder: folderID, in: project)
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))
        fixture.library.reload(project)

        XCTAssertFalse(model.confirmTermination())

        XCTAssertEqual(fixture.system.quitConfirmations, 1)
        XCTAssertNil(model.alert, "cancelling the quit keeps the draft rather than discarding it")
    }

    func testAnExternalDeleteMovesTheSelectionToTheProject() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        try fixture.library.mutate(project) { try $0.removeNode(request) }
        model.libraryDidChange()

        XCTAssertEqual(model.selection, .project(project))
    }

    func testTheActiveEnvironmentFallsBackToDefault() throws {
        let project = try makeProject()
        let document = try XCTUnwrap(fixture.library.document(project))

        XCTAssertEqual(model.activeEnvironmentID(for: project), document.defaultEnvironment.id)
        model.setActiveEnvironment(EnvironmentID(), for: project)
        XCTAssertEqual(model.activeEnvironmentID(for: project), document.defaultEnvironment.id)
    }

    func testEditorsSeeGlobalBeneathDefaultAndFollowItsChanges() throws {
        let project = try makeProject()
        try fixture.library.mutate(project) { $0.defaultEnvironment.variables = [Variable(key: "host", value: "project")] }
        XCTAssertNil(model.tokenContext(for: project).entries["region"])

        try fixture.library.mutateGlobalEnvironment { global in
            global.variables = [Variable(key: "host", value: "global"), Variable(key: "region", value: "eu")]
        }

        let context = model.tokenContext(for: project)
        XCTAssertEqual(context.entries["region"], TemplateTokenContext.Entry(displayValue: "eu", sourceName: "Global"))
        XCTAssertEqual(context.entries["host"]?.displayValue, "project")
    }

    /// Postman's names for `$uuid` read as built-ins, not red, yet completion offers only Reqling's own.
    func testPostmansUUIDNamesReadAsBuiltInsWithoutBeingOffered() throws {
        let context = model.tokenContext(for: try makeProject())
        let tokens = TemplateParser.tokens(in: "{{$guid}} {{$randomUUID}} {{$randomNope}}")

        XCTAssertEqual(tokens.map(context.state(for:)), [.dynamic, .dynamic, .unresolved])
        XCTAssertEqual(context.completions(matching: "$"), DynamicVariables.names)
    }

    // MARK: - Proto workspaces

    func testProtoWorkspacesFollowEachProjectsProtoDefinitions() throws {
        let withProtos = try makeProject()
        model.createProject(named: "Other")
        let without = try XCTUnwrap(model.selection?.projectID)
        let protos = ProjectGRPCConfiguration(protoRoots: [.relative("protos")])
        try fixture.library.mutate(withProtos) { $0.grpc = protos }
        model.libraryDidChange()

        let store = fixture.component.protoWorkspaces
        XCTAssertEqual(Set(store.workspaces.keys), [withProtos])
        XCTAssertEqual(store.workspace(for: withProtos)?.configuration, protos)
        XCTAssertNil(store.workspace(for: without))

        let edited = ProjectGRPCConfiguration(protoRoots: [.relative("protos")], protoFiles: ["acme/v1/users.proto"])
        try fixture.library.mutate(withProtos) { $0.grpc = edited }
        model.libraryDidChange()
        XCTAssertEqual(store.workspace(for: withProtos)?.configuration, edited)

        try fixture.library.mutate(withProtos) { $0.grpc = ProjectGRPCConfiguration() }
        model.libraryDidChange()
        XCTAssertTrue(store.workspaces.isEmpty, "clearing a project's protos drops its workspace")

        try fixture.library.mutate(without) { $0.grpc = protos }
        model.libraryDidChange()
        model.removeProject(without)
        model.libraryDidChange()
        XCTAssertTrue(store.workspaces.isEmpty, "removing a project drops its workspace")
    }

    func testLaunchingCreatesWorkspacesForProjectsWithProtos() throws {
        let project = try makeProject()
        try fixture.library.mutate(project) { $0.grpc = ProjectGRPCConfiguration(descriptorSets: [.relative("api.protoset")]) }
        XCTAssertNil(fixture.component.protoWorkspaces.workspace(for: project))

        _ = relaunch()

        XCTAssertNotNil(fixture.component.protoWorkspaces.workspace(for: project))
    }

    func testAProjectThatDidNotLoadKeepsItsWorkspace() throws {
        let project = try makeProject()
        try fixture.library.mutate(project) { $0.grpc = ProjectGRPCConfiguration(protoRoots: [.relative("protos")]) }
        model.libraryDidChange()
        let workspace = try XCTUnwrap(fixture.component.protoWorkspaces.workspace(for: project))

        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))
        fixture.library.reload(project)
        model.libraryDidChange()

        XCTAssertNil(fixture.library.document(project))
        XCTAssertTrue(fixture.component.protoWorkspaces.workspace(for: project) === workspace)
    }

    /// The badged gear goes straight to App Updates; the plain one keeps Settings' last page.
    func testTheGearOpensAppUpdatesOnlyWhileItHasABadge() async {
        let updates = AppUpdateStubs.manager(AppUpdateStubs.newer)
        let badged = AppFixture(updates: updates)
        defer { badged.tearDown() }
        badged.model.settingsPage = .interface

        badged.model.openSettingsFromToolbar()
        XCTAssertEqual(badged.model.settingsPage, .interface)
        badged.model.openSettingsFromToolbar()
        XCTAssertFalse(badged.model.isShowingSettings, "A second click closes Settings")

        await updates.forceCheck()
        badged.model.openSettingsFromToolbar()
        XCTAssertTrue(badged.model.isShowingSettings)
        XCTAssertEqual(badged.model.settingsPage, .updates)
    }

    /// Once the helper starts it installs on the next quit, so a refused quit must stop the install before it starts,
    /// and an agreed one must not ask again when the update quits Reqling.
    func testInstallingAsksAboutUnsavedEditsBeforeTheHelperStarts() async throws {
        let installer = StubUpdateInstaller()
        let updates = AppUpdateStubs.manager(AppUpdateStubs.newer, installer: installer)
        fixture.tearDown()
        fixture = AppFixture(updates: updates)
        await updates.downloadLatestUpdate()
        let project = try makeProject()
        model.newFolder()
        let folderID = try XCTUnwrap(model.selection?.nodeID)
        model.setAuth(.bearer(token: "a"), forFolder: folderID, in: project)
        let root = try XCTUnwrap(fixture.library.project(project)?.url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))
        fixture.library.reload(project)

        model.installUpdate()
        XCTAssertEqual(fixture.system.quitConfirmations, 1)
        XCTAssertFalse(model.isQuittingForUpdate)

        fixture.system.quitsDiscardingUnsavedChanges = true
        model.installUpdate()
        await waitUntil("the install") { installer.installs == 1 }

        XCTAssertEqual(installer.installs, 1, "Only the agreed install runs")
        XCTAssertTrue(model.confirmTermination())
        XCTAssertEqual(fixture.system.quitConfirmations, 2, "The update's own quit doesn't ask again")
    }

    func testTurningUpdateChecksOffPersists() {
        fixture.model.setChecksForUpdatesAutomatically(false)

        XCTAssertFalse(fixture.model.settings.settings.checksForUpdatesAutomatically)
        fixture.model.setChecksForUpdatesAutomatically(true)
        XCTAssertTrue(fixture.model.settings.settings.checksForUpdatesAutomatically)
        fixture.model.updates.stopAutomaticChecks()
    }

}
