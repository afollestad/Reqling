import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// Files chosen for a project: references kept across Macs, and outside paths forgotten once unused.
@MainActor
extension AppModelTests {
    /// A this-Mac-only reference chosen on another Mac keeps its ID when it's chosen here, so the other Mac's file for
    /// it stays chosen there once the change syncs; one with a file here gets a new ID, leaving copies that share it.
    func testChoosingAFileForAReferenceFromAnotherMacKeepsItsID() throws {
        let project = try makeProject()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).bin")
        let fromElsewhere = ProjectPathReference.local(LocalPathID())
        fixture.system.pathSharing = .thisMacOnly

        let repointed = model.reference(for: outside, in: project, replacing: fromElsewhere)
        let replaced = model.reference(for: outside, in: project, replacing: repointed)

        XCTAssertNotEqual(repointed, fromElsewhere, "Not referenced by the project yet, so nothing to keep")
        XCTAssertNotEqual(replaced, fromElsewhere)

        var spec = HTTPRequestSpec(url: "https://api/upload")
        spec.body.binary.file = fromElsewhere
        let original = RequestItem(name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { $0.items = [.request(original)] }
        XCTAssertEqual(model.reference(for: outside, in: project, replacing: fromElsewhere), fromElsewhere)

        let elsewhereAgain = ProjectPathReference.local(LocalPathID())
        spec.body.binary.file = elsewhereAgain
        let shared = RequestItem(name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { $0.items = [.request(shared), RequestNode.request(shared).copy()] }
        XCTAssertNotEqual(model.reference(for: outside, in: project, replacing: elsewhereAgain), elsewhereAgain, "A copy shares it")
    }

    /// A chosen outside path the project no longer references is forgotten on load, so the same path written in later
    /// by someone else isn't trusted.
    func testLoadingForgetsChosenOutsidePathsTheProjectNoLongerUses() throws {
        let project = try makeProject()
        let workspace = fixture.component.workspaceState
        workspace.addChosenOutsidePath("../gone.bin", in: project)

        model.lifecycle.reconcileLocalPaths(in: project)

        XCTAssertEqual(workspace.chosenOutsidePaths(in: project), [])
    }
}
