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
        _ = store.addLocalPath("/Users/me/cert.p12", in: ProjectID())

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
        guard case .local(let kept) = store.addLocalPath("/protos", in: project),
              case .local(let dropped) = store.addLocalPath("/removed", in: project) else {
            return XCTFail("Expected local references")
        }

        store.reconcileLocalPaths(in: project, keeping: [kept, unscoped])

        XCTAssertEqual(store.localPaths(in: project), [kept: "/protos", unscoped: "/old/cert.p12"])
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
        _ = store.addLocalPath("/protos", in: project)

        store.forgetProject(project)

        XCTAssertFalse(store.projectState(project).isCollapsed)
        XCTAssertEqual(store.localPaths(in: project).count, 1, "Adding the folder back still finds its files")

        store.forgetProject(project, keepingLocalPaths: false)

        XCTAssertNil(store.state.projects[project.description])
    }

    func testEveryFieldHoldingAReferenceCountsAsUsed() throws {
        let ids = (0..<8).map { _ in LocalPathID() }
        var http = HTTPRequestSpec()
        http.body.binary.file = .local(ids[0])
        http.body.formData = [MultipartField(key: "upload", kind: .file, file: .local(ids[1]))]
        let grpc = GRPCRequestSpec(schema: .descriptorSet(.local(ids[2])))
        let document = ProjectDocument(
            name: "API",
            tls: ProjectTLSConfiguration(
                clientCertificates: [
                    ClientCertificateEntry(hostPattern: "*", source: .pkcs12(.local(ids[3]))),
                    ClientCertificateEntry(hostPattern: "*.internal", source: .pem(certificate: .local(ids[6]), key: .local(ids[7])))
                ],
                caCertificates: [.local(ids[4]), .relative("ca.pem")]
            ),
            grpc: ProjectGRPCConfiguration(protoRoots: [.local(ids[5])], descriptorSets: [.relative("api.binpb")]),
            items: [
                .request(RequestItem(name: "Upload", kind: .http(http))),
                .folder(RequestFolder(name: "RPC", children: [.request(RequestItem(name: "Echo", kind: .grpc(grpc)))]))
            ]
        )

        XCTAssertEqual(document.localPathIDs, Set(ids))
    }
}
