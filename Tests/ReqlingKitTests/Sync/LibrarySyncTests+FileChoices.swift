import Foundation
@testable import ReqlingKit
import XCTest

/// Files chosen on one Mac against changes from another: another Mac can name a reference and move it, but a file
/// chosen here is read only where it was chosen.
@MainActor
extension LibrarySyncTests {
    /// Mac A moves the reference to Mac B's client key into a request body: Mac B won't read the key for it.
    func testAClientKeyMovedIntoABodyByAnotherMacStaysUnreadable() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macA, id)).id
        let key = macB.storage.directory.file("client.p12")
        try Data("private key".utf8).write(to: key)
        let entry = CertificateEntryID()
        let reference = macB.workspace.addLocalPath(key.path, for: .clientCertificate(entry), in: id)
        try macB.library.mutate(id) { document in
            document.tls.clientCertificates = [ClientCertificateEntry(id: entry, hostPattern: "api.example.com", source: .pkcs12(reference))]
        }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        try setBinaryBody(reference, of: requestID, on: macA, in: id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(request(in: macB, id)?.kind.httpSpec?.body.binary.file, reference)
        let paths = try XCTUnwrap(macB.lifecycle.pathResolver(for: id))
        XCTAssertNil(paths.url(for: reference, in: .binaryBody(requestID)))
        XCTAssertEqual(try paths.identityData(for: reference, in: .clientCertificate(entry)), Data("private key".utf8), "TLS still reads it")
    }

    /// Mac A moves the file Mac B chose for one request's body into another request: Mac B sends it only from the first.
    func testAFileMovedIntoAnotherRequestByAnotherMacIsMissingThere() async throws {
        let id = try await shareProject()
        let chosen = try XCTUnwrap(request(in: macA, id)).id
        let other = RequestItem(name: "Elsewhere", kind: .http(HTTPRequestSpec(url: "https://example.net/upload")))
        try macA.library.mutate(id) { try $0.insert(.request(other), into: nil) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        let file = macB.storage.directory.file("upload.bin")
        try Data("private".utf8).write(to: file)
        let reference = macB.workspace.addLocalPath(file.path, for: .binaryBody(chosen), in: id)
        try setBinaryBody(reference, of: chosen, on: macB, in: id)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        try setBinaryBody(reference, of: other.id, on: macA, in: id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.request(other.id)?.kind.httpSpec?.body.binary.file, reference)
        XCTAssertThrowsError(try macB.runner.prepareRun(other.id, in: id, options: RunOptions())) { error in
            XCTAssertTrue("\(error)".contains("A file chosen for another field"), "\(error)")
        }
        let sent = try macB.runner.prepareRun(chosen, in: id, options: RunOptions())
        XCTAssertEqual(sent.prepared.urlRequest.httpBody, Data("private".utf8))
    }

    /// A file chosen before slots were recorded is settled where this Mac's copy holds it before another Mac's change
    /// lands, so a change that moves it isn't where the next launch takes it to belong; that launch keeps it only where
    /// it's still held, which is nowhere.
    func testAFileChosenBeforeSlotsIsSettledBeforeAnotherMacMovesIt() async throws {
        let id = try await shareProject()
        let chosen = try XCTUnwrap(request(in: macA, id)).id
        let other = RequestItem(name: "Elsewhere", kind: .http(HTTPRequestSpec(url: "https://example.net/upload")))
        try macA.library.mutate(id) { try $0.insert(.request(other), into: nil) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        let pathID = LocalPathID()
        macB.workspace.updateProject(id) { $0.localPaths[pathID.description] = "/Users/me/upload.bin" }
        try setBinaryBody(.local(pathID), of: chosen, on: macB, in: id)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        try setBinaryBody(.local(pathID), of: other.id, on: macA, in: id)
        try setBinaryBody(nil, of: chosen, on: macA, in: id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        let settled = macB.workspace.choices(in: id)
        macB.lifecycle.reconcileFileChoices(in: id)

        XCTAssertEqual(settled, [.local(pathID): [.binaryBody(chosen)]])
        XCTAssertEqual(macB.workspace.choices(in: id), [.local(pathID): []])
    }

    private func setBinaryBody(_ reference: ProjectPathReference?, of request: RequestNodeID, on mac: SyncTestMac, in project: ProjectID) throws {
        try mac.library.mutate(project) { try $0.updateNode(request) { node in
            if case .request(var item) = node, case .http(var spec) = item.kind {
                spec.method = .post
                spec.body.mode = .binary
                spec.body.binary.file = reference
                item.kind = .http(spec)
                node = .request(item)
            }
        } }
    }
}
