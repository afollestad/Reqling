import Foundation
@testable import ReqlingKit
import XCTest

/// A Postman import written as a new project: its files, its secrets kept apart, its trust, and its body files.
@MainActor
final class ProjectLifecycleProjectImportTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var workspace: WorkspaceStateStore!
    private var suiteName: String!
    private var lifecycle: ProjectLifecycle!

    override func setUp() async throws {
        fixture = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: fixture.directory.file("Support/workspace.json"))
        suiteName = "com.afollestad.reqling.tests.postman-import.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let runner = RequestRunner(
            library: fixture.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            history: RunHistory(directory: fixture.directory.file("Support/History"), settings: settings),
            userAgent: "Reqling/1.0",
            scripts: HelperScriptRunner(executable: nil, runtimeDirectory: nil)
        )
        let protoWorkspaces = ProtoWorkspaceStore(environment: ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: fixture.directory.file("Support/ProtocCache")),
            locateProtoc: { nil },
            changes: { _ in AsyncStream { $0.finish() } }
        ))
        lifecycle = ProjectLifecycle(library: fixture.library, runner: runner, workspace: workspace, protoWorkspaces: protoWorkspaces)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fixture.directory.remove()
    }

    private func petstore(files: [String] = []) throws -> ProjectImport {
        let collection = try PostmanImporterTests.collection(PostmanImporterTests.file("petstore.postman_collection"))
        return PostmanImporter.plan(collection, files: try files.map(PostmanImporterTests.file), collectionDirectory: nil)
    }

    func testAnImportIsWrittenWithItsScriptsBesideItsFilesAndItsSecretsInTheKeychain() throws {
        let result = try lifecycle.importProject(try petstore(files: ["staging.postman_environment", "workspace.postman_globals"]), named: "Petstore")
        let id = result.project
        let document = try XCTUnwrap(fixture.library.document(id))

        XCTAssertEqual(document.name, "Petstore")
        XCTAssertEqual(document.items.map(\.name), ["Auth", "Pets"])
        XCTAssertEqual(document.allEnvironments.map(\.name), ["Default", "Staging"])
        XCTAssertEqual(try fixture.contents("project.pre.js", in: id), "utils = { stamp: () => Date.now() }")
        XCTAssertTrue(fixture.exists("requests/auth/login.post.js", in: id))
        let projectText = try allText(in: fixture.projectURL(id))
        for secret in ["hunter2", "abc123", "k-123", "s3cr3t"] {
            XCTAssertFalse(projectText.contains(secret), "\(secret) is in the project's files")
        }
        let stored = try fixture.secrets.secrets(for: .project(id)).values
        XCTAssertEqual(Set(stored), ["hunter2", "abc123", "k-123", "s3cr3t"])
        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.value), ["eu"])
        XCTAssertEqual(result.globalChange, ImportEnvironmentChange(environment: "Global", isNew: false, added: ["region"], updated: []))
        XCTAssertEqual(workspace.projectState(id).scriptTrust, .unknown, "someone else wrote its scripts")
    }

    func testAnImportWithoutScriptsTrustsThemLikeANewProject() throws {
        let plan = PostmanImporter.plan(
            try PostmanImporterTests.collection(PostmanFile.read(Data(#"{"info": {"name": "Plain"}, "item": []}"#.utf8), named: "plain.json")),
            files: [],
            collectionDirectory: nil
        )

        let id = try lifecycle.importProject(plan, named: "Plain").project

        XCTAssertEqual(workspace.projectState(id).scriptTrust, .trusted)
    }

    /// A file in the project's repository is shared by a relative path; one elsewhere is kept on this Mac only.
    func testBodyFilesArePointedAtAsTheyWouldBeIfChosen() throws {
        let repository = fixture.directory.file("Repo")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("files"), withIntermediateDirectories: true)
        let inside = repository.appendingPathComponent("files/inside.png")
        let outside = fixture.directory.file("outside.png")
        try Data("a".utf8).write(to: inside)
        try Data("b".utf8).write(to: outside)
        let json = """
        {"info": {"name": "Files"}, "item": [
          {"name": "Inside", "request": {"method": "PUT", "url": "https://x", "body": {"mode": "file", "file": {"src": "\(inside.path)"}}}},
          {"name": "Outside", "request": {"method": "PUT", "url": "https://x", "body": {"mode": "file", "file": {"src": "\(outside.path)"}}}}]}
        """
        let plan = PostmanImporter.plan(try PostmanImporterTests.collection(PostmanFile.read(Data(json.utf8), named: "files.json")),
                                        files: [], collectionDirectory: nil)

        let id = try lifecycle.importProject(plan, named: "Files", in: repository).project

        let files = try XCTUnwrap(fixture.library.document(id)).items.compactMap { node -> ProjectPathReference? in
            guard case .request(let request) = node else {
                return nil
            }
            return request.kind.httpSpec?.body.binary.file
        }
        XCTAssertEqual(files.first, .relative("../files/inside.png"))
        guard case .local(let local)? = files.last else {
            return XCTFail("a file outside the repository is this Mac's alone")
        }
        XCTAssertEqual(workspace.projectState(id).localPaths[local.description], outside.path)
    }

    func testAFailedSaveLeavesNoProjectBehind() throws {
        let plan = try petstore()
        fixture.secrets.isFailingReads = true

        XCTAssertThrowsError(try lifecycle.importProject(plan, named: "Petstore"))

        XCTAssertTrue(fixture.library.projects.isEmpty)
        XCTAssertEqual(fixture.trashedNames(), ["Petstore.reqling"])
    }

    /// Every file's text under `directory`, joined.
    private func allText(in directory: URL) throws -> String {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}
