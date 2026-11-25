@testable import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    /// A project shared to view: only secret values take input, and Save as Value and the environment controls are gone.
    func testEnvironmentEditorSharedToView() throws {
        let project = try SnapshotProject.make(in: fixture)
        fixture.library.setSharing(ProjectSharing(owner: "owner", permission: .readOnly, canInvite: false), for: project.id)
        let editor = EnvironmentEditorModel(projectID: project.id, app: fixture.model)

        assertBothAppearances(EnvironmentEditorSheet(editor: editor), size: CGSize(width: 760, height: 480))
    }

    /// A project someone else shares is marked beside its name.
    func testSidebarMarksSharedProjects() throws {
        let project = try SnapshotProject.make(in: fixture)
        fixture.library.setSharing(ProjectSharing(owner: "owner", permission: .readWrite, canInvite: false, ownerName: "Ann"), for: project.id)

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    /// Before a project is first shared: the Global variables it uses, ticked to copy into its Default.
    func testShareProjectSheet() throws {
        let project = try SnapshotProject.make(in: fixture)
        let offer = GlobalVariablesOffer(
            variables: [Variable(key: "baseUrl", value: "https://api"), Variable(key: "token", value: "s3cret", isSecret: true)],
            readThroughGlobals: ["tenant"]
        )

        let sheet = ShareProjectSheet(model: fixture.model, projectID: project.id, origin: .sidebar(project.id), offer: offer)
        assertBothAppearances(sheet, size: CGSize(width: 460, height: 360))
    }
}
