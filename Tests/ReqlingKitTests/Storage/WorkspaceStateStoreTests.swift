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
        _ = store.addLocalPath("/Users/me/cert.p12", for: .caCertificates, in: ProjectID())

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasPrefix("workspace.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.file(backups[0]), encoding: .utf8), "{ broken")
        XCTAssertEqual(WorkspaceStateStore(fileURL: file).state, store.state)
    }

    func testReconcilingKeepsOnlyReferencedPathsAndClaimsUnscopedOnes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.file("workspace.json")
        let unscoped = LocalPathID()
        let otherProjects = LocalPathID()
        try #"{"localPaths": {"\#(unscoped)": "/old/cert.p12", "\#(otherProjects)": "/old/theirs"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceStateStore(fileURL: file)
        let project = ProjectID()
        guard case .local(let kept) = store.addLocalPath("/protos", for: .protoRoots, in: project),
              case .local(let dropped) = store.addLocalPath("/removed", for: .protoRoots, in: project) else {
            return XCTFail("Expected local references")
        }

        store.reconcileChoices(in: project, holding: [
            PlacedPathReference(.local(kept), in: .protoRoots),
            PlacedPathReference(.local(unscoped), in: .caCertificates)
        ])

        XCTAssertEqual(store.localPaths(in: project), [kept: "/protos", unscoped: "/old/cert.p12"])
        XCTAssertEqual(store.choices(in: project), [.local(kept): [.protoRoots], .local(unscoped): [.caCertificates]], "Claimed where it's held")
        XCTAssertNil(store.localPath(dropped, in: project))
        XCTAssertEqual(store.state.unclaimedLocalPaths, [otherProjects.description: "/old/theirs"], "Another project may still claim it")
        XCTAssertEqual(WorkspaceStateStore(fileURL: file).state, store.state)
    }

    func testForgettingAProjectKeepsItsLocalPathsUnlessItWasDeleted() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = WorkspaceStateStore(fileURL: directory.file("workspace.json"))
        let project = ProjectID()
        store.updateProject(project) { $0.isCollapsed = true }
        let root = store.addLocalPath("/protos", for: .protoRoots, in: project)
        store.addChosenOutsidePath("../schemas/api.graphql", for: .protoRoots, in: project)
        let choices: [ProjectPathReference: Set<ProjectPathSlot>] = [root: [.protoRoots], .relative("../schemas/api.graphql"): [.protoRoots]]

        store.forgetProject(project)

        XCTAssertFalse(store.projectState(project).isCollapsed)
        XCTAssertEqual(store.choices(in: project), choices, "Adding the folder back still finds its files, where they were chosen")
        XCTAssertEqual(WorkspaceStateStore(fileURL: directory.file("workspace.json")).choices(in: project), choices)

        store.forgetProject(project, keepingLocalPaths: false)

        XCTAssertNil(store.state.projects[project.description])
    }

    /// A state file from before the inspector had panels shows the run history, as it did then.
    func testTheInspectorPanelDefaultsToHistoryAndRoundTrips() throws {
        let old = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"showsRunHistory": true}"#.utf8))
        var state = WorkspaceState()
        state.inspectorPanel = .graphQLSchema

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        let unknown = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"inspectorPanel": "timeline"}"#.utf8))

        XCTAssertTrue(old.showsRunHistory)
        XCTAssertEqual(old.inspectorPanel, .history)
        XCTAssertEqual(decoded.inspectorPanel, .graphQLSchema)
        XCTAssertEqual(unknown.inspectorPanel, .history)
    }

    func testEveryFieldHoldingAReferenceIsPlacedInItsOwnSlot() throws {
        let ids = (0..<9).map { _ in LocalPathID() }
        var http = HTTPRequestSpec()
        http.body.binary.file = .local(ids[0])
        let field = MultipartField(key: "upload", kind: .file, file: .local(ids[1]))
        http.body.formData = [field]
        http.body.graphQL.schema = .file(.local(ids[8]))
        let grpc = GRPCRequestSpec(schema: .descriptorSet(.local(ids[2])))
        let upload = RequestItem(name: "Upload", kind: .http(http))
        let echo = RequestItem(name: "Echo", kind: .grpc(grpc))
        let pkcs12 = ClientCertificateEntry(hostPattern: "*", source: .pkcs12(.local(ids[3])))
        let pem = ClientCertificateEntry(hostPattern: "*.internal", source: .pem(certificate: .local(ids[6]), key: .local(ids[7])))
        let document = ProjectDocument(
            name: "API",
            tls: ProjectTLSConfiguration(clientCertificates: [pkcs12, pem], caCertificates: [.local(ids[4]), .relative("ca.pem")]),
            grpc: ProjectGRPCConfiguration(protoRoots: [.local(ids[5])], descriptorSets: [.relative("api.binpb")]),
            items: [.request(upload), .folder(RequestFolder(name: "RPC", children: [.request(echo)]))]
        )

        XCTAssertEqual(Set(document.placedReferences), [
            PlacedPathReference(.local(ids[0]), in: .binaryBody(upload.id)),
            PlacedPathReference(.local(ids[1]), in: .formField(upload.id, field.id)),
            PlacedPathReference(.local(ids[8]), in: .graphQLSchema(upload.id)),
            PlacedPathReference(.local(ids[2]), in: .descriptorSet(echo.id)),
            PlacedPathReference(.local(ids[3]), in: .clientCertificate(pkcs12.id)),
            PlacedPathReference(.local(ids[6]), in: .clientCertificate(pem.id)),
            PlacedPathReference(.local(ids[7]), in: .clientCertificate(pem.id)),
            PlacedPathReference(.local(ids[4]), in: .caCertificates),
            PlacedPathReference(.relative("ca.pem"), in: .caCertificates),
            PlacedPathReference(.local(ids[5]), in: .protoRoots),
            PlacedPathReference(.relative("api.binpb"), in: .projectDescriptorSets)
        ])
    }

    /// A choice recorded before slots were takes the slots its reference holds when its project loads, once: after
    /// that, wherever another Mac moves it, it never resolves there.
    func testAChoiceFromBeforeSlotsTakesWhereItsHeldOnLoad() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.file("workspace.json")
        let project = ProjectID()
        let id = LocalPathID()
        let body = ProjectPathSlot.binaryBody(RequestNodeID())
        let other = ProjectPathSlot.binaryBody(RequestNodeID())
        let state = #"{"projects": {"\#(project)": {"localPaths": {"\#(id)": "/body.bin"}, "chosenOutsidePaths": ["../schema.json"]}}}"#
        try state.write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceStateStore(fileURL: file)
        XCTAssertEqual(store.choices(in: project), [:], "Nowhere until its project loads")

        store.reconcileChoices(in: project, holding: [
            PlacedPathReference(.local(id), in: body),
            PlacedPathReference(.relative("../schema.json"), in: .caCertificates)
        ])
        store.reconcileChoices(in: project, holding: [
            PlacedPathReference(.local(id), in: other),
            PlacedPathReference(.relative("../schema.json"), in: .protoRoots)
        ])

        XCTAssertEqual(store.choices(in: project), [.local(id): [], .relative("../schema.json"): []])
    }

    /// On load, a choice keeps only the slots still holding it, so a request deleted since, or a field whose file was
    /// replaced, can't be named by someone else's change to read it again; it never gains the slots it was moved into.
    func testLoadingKeepsAChoiceOnlyWhereItsStillHeld() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = WorkspaceStateStore(fileURL: directory.file("workspace.json"))
        let project = ProjectID()
        let (kept, deleted, movedInto) = (RequestNodeID(), RequestNodeID(), RequestNodeID())
        let body = store.addLocalPath("/body.bin", for: .binaryBody(kept), in: project)
        store.choose(body, for: .binaryBody(deleted), in: project)
        store.addChosenOutsidePath("../ca.pem", for: .caCertificates, in: project)

        store.reconcileChoices(in: project, holding: [
            PlacedPathReference(body, in: .binaryBody(kept)),
            PlacedPathReference(body, in: .binaryBody(movedInto)),
            PlacedPathReference(.relative("../ca.pem"), in: .protoRoots)
        ])

        XCTAssertEqual(store.choices(in: project), [body: [.binaryBody(kept)], .relative("../ca.pem"): []])
    }

    /// Before another Mac's change lands, a choice from before slots takes where this Mac's copy holds it; with no copy
    /// here to say, it's forgotten.
    func testAChoiceFromBeforeSlotsIsSettledOrForgottenBeforeAnotherMacsChange() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.file("workspace.json")
        let settled = ProjectID()
        let adopted = ProjectID()
        let id = LocalPathID()
        let body = ProjectPathSlot.binaryBody(RequestNodeID())
        let paths = #"{"localPaths": {"\#(id)": "/body.bin"}, "chosenOutsidePaths": ["../schema.json"]}"#
        try #"{"projects": {"\#(settled)": \#(paths), "\#(adopted)": \#(paths)}}"#.write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceStateStore(fileURL: file)

        store.slotUnslottedChoices(in: settled, holding: [PlacedPathReference(.local(id), in: body)])
        store.forgetUnslottedChoices(in: adopted)

        XCTAssertEqual(store.choices(in: settled), [.local(id): [body], .relative("../schema.json"): []])
        XCTAssertEqual(store.projectState(adopted).localPaths, [:])
        XCTAssertEqual(store.projectState(adopted).chosenOutsidePaths, [])
    }

    /// A slot a newer Reqling wrote drops alone, leaving its choice recorded rather than taken for one from before slots.
    func testAnUnknownSlotDropsAloneAndChoicesRoundTrip() throws {
        let project = ProjectID()
        let id = LocalPathID()
        let body = ProjectPathSlot.binaryBody(RequestNodeID())
        var state = WorkspaceState()
        state.projects[project.description] = ProjectWorkspaceState()
        state.projects[project.description]?.localPaths = [id.description: "/body.bin"]
        state.projects[project.description]?.localPathSlots = [id.description: [body]]
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: encoded)
        let newer = #"{"projects": {"\#(project)": {"localPaths": {"\#(id)": "/body.bin"}, "localPathSlots": {"\#(id)": ["headerFile/x"]}}}}"#

        let unreadable = #"{"projects": {"\#(project)": {"localPaths": {"\#(id)": "/body.bin"}, "localPathSlots": ["binaryBody/x"]}}}"#

        let unknown = try JSONDecoder().decode(WorkspaceState.self, from: Data(newer.utf8))
        let unread = try JSONDecoder().decode(WorkspaceState.self, from: Data(unreadable.utf8))

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(unknown.projects[project.description]?.localPathSlots, [id.description: []])
        XCTAssertEqual(unread.projects[project.description]?.localPathSlots, [id.description: []], "Chosen for nothing, not settled anew")
    }
}
