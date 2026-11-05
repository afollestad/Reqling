import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    func testEnvironmentEditor() throws {
        let project = try SnapshotProject.make(in: fixture)
        let editor = EnvironmentEditorModel(projectID: project.id, app: fixture.model)

        assertBothAppearances(EnvironmentEditorSheet(editor: editor), size: CGSize(width: 760, height: 480))
    }

    func testEnvironmentEditorGlobal() throws {
        let project = try SnapshotProject.make(in: fixture)
        try fixture.library.mutateGlobalEnvironment { global in
            global.variables = [Variable(key: "region", value: "eu-west-1"), Variable(key: "apiKey", value: "global-key", isSecret: true)]
        }
        let editor = EnvironmentEditorModel(projectID: project.id, app: fixture.model)
        editor.selectedID = editor.globalEnvironment.id

        assertBothAppearances(EnvironmentEditorSheet(editor: editor), size: CGSize(width: 760, height: 480))
    }

    func testProjectSettings() async throws {
        let project = try SnapshotProject.make(in: fixture)
        let settings = ProjectSettingsModel(projectID: project.id, app: fixture.model)
        settings.clientCertificates = [
            ClientCertificateEntry(hostPattern: "*.internal", source: .pkcs12(.relative("client.p12"))),
            ClientCertificateEntry(hostPattern: "api.example.com", source: .pem(certificate: .relative("client.crt"), key: .relative("client.key")))
        ]
        // The rows check their certificates from a task the snapshot would not wait for.
        for entry in settings.clientCertificates {
            await settings.refreshStatus(of: entry)
        }

        assertBothAppearances(
            ProjectSettingsSheet(settings: settings, tokenContext: TemplateTokenContext(scope: fixture.model.scope(for: project.id))),
            size: CGSize(width: 640, height: 600)
        )
    }

    func testSettingsWide() {
        fixture.model.showSettings(.requests)

        // Wide enough that capping the content's width would show as a trailing gap wider than the leading inset.
        assertBothAppearances(SettingsScreen(model: fixture.model), size: CGSize(width: 1200, height: 460))
    }

    func testSettingsCompact() {
        fixture.model.showSettings(.interface)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: CGSize(width: 520, height: 400))
    }
}
