import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// Files chosen for a project: references kept across Macs, and outside paths forgotten once unused.
@MainActor
extension AppModelTests {
    /// A this-Mac-only reference chosen on another Mac keeps its ID when it's chosen here, so the other Mac's file for
    /// it stays chosen there once the change syncs; one with a file here gets a new ID, leaving copies that share it,
    /// or the field another Mac moved it from, its own file.
    func testChoosingAFileForAReferenceFromAnotherMacKeepsItsID() throws {
        let project = try makeProject()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).bin")
        let fromElsewhere = ProjectPathReference.local(LocalPathID())
        let requestID = RequestNodeID()
        let body = ProjectPathSlot.binaryBody(requestID)
        fixture.system.pathSharing = .thisMacOnly

        let repointed = model.reference(for: outside, in: project, at: body, replacing: fromElsewhere)
        let replaced = model.reference(for: outside, in: project, at: body, replacing: repointed)

        XCTAssertNotEqual(repointed, fromElsewhere, "Not referenced by the project yet, so nothing to keep")
        XCTAssertNotEqual(replaced, repointed, "It has a file here, which another field may hold it for")

        var spec = HTTPRequestSpec(url: "https://api/upload")
        spec.body.binary.file = fromElsewhere
        let original = RequestItem(id: requestID, name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { $0.items = [.request(original)] }
        XCTAssertEqual(model.reference(for: outside, in: project, at: body, replacing: fromElsewhere), fromElsewhere)
        XCTAssertEqual(model.pathResolver(for: project)?.url(for: fromElsewhere, in: body)?.path, outside.path)

        let elsewhereAgain = ProjectPathReference.local(LocalPathID())
        spec.body.binary.file = elsewhereAgain
        let shared = RequestItem(name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { $0.items = [.request(shared), RequestNode.request(shared).copy()] }
        let again = model.reference(for: outside, in: project, at: .binaryBody(shared.id), replacing: elsewhereAgain)
        XCTAssertNotEqual(again, elsewhereAgain, "A copy shares it")
    }

    /// A chosen outside path the project no longer references is forgotten on load, so the same path written in later
    /// by someone else isn't trusted.
    func testLoadingForgetsChosenOutsidePathsTheProjectNoLongerUses() throws {
        let project = try makeProject()
        let workspace = fixture.component.workspaceState
        workspace.addChosenOutsidePath("../gone.bin", for: .caCertificates, in: project)

        model.lifecycle.reconcileFileChoices(in: project)

        XCTAssertEqual(workspace.choices(in: project), [:])
    }

    /// A duplicate's files are chosen for it as they were for its original, the person's own doing; one another Mac
    /// moved into the original stays missing in the copy too.
    func testADuplicateKeepsTheFilesChosenForItsOriginal() throws {
        let project = try makeProject()
        let workspace = fixture.component.workspaceState
        let requestID = RequestNodeID()
        let field = MultipartFieldID()
        let chosen = workspace.addLocalPath("/files/upload.bin", for: .formField(requestID, field), in: project)
        let movedIn = workspace.addLocalPath("/files/other.bin", for: .binaryBody(RequestNodeID()), in: project)
        var spec = HTTPRequestSpec()
        spec.body.formData = [MultipartField(id: field, key: "upload", kind: .file, file: chosen)]
        spec.body.binary.file = movedIn
        let folder = RequestFolder(name: "Uploads", children: [.request(RequestItem(id: requestID, name: "Upload", kind: .http(spec)))])
        try fixture.library.mutate(project) { try $0.insert(.folder(folder), into: nil) }

        model.duplicate(folder.id, in: project)

        let copy = try XCTUnwrap(model.selection?.nodeID.flatMap { fixture.library.document(project)?.folder($0) })
        let copiedRequest = try XCTUnwrap(copy.children.first?.id)
        let resolver = try XCTUnwrap(model.pathResolver(for: project))
        XCTAssertNotEqual(copiedRequest, requestID)
        XCTAssertEqual(resolver.url(for: chosen, in: .formField(copiedRequest, field))?.path, "/files/upload.bin")
        XCTAssertNil(resolver.url(for: movedIn, in: .binaryBody(copiedRequest)))
        XCTAssertNil(resolver.url(for: movedIn, in: .binaryBody(requestID)))
    }
}
