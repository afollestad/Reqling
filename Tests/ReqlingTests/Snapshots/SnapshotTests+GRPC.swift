import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    private static let settingsSize = CGSize(width: 900, height: 560)
    private static let protoDefinitionsSize = CGSize(width: 640, height: 740)

    func testSettingsGRPCFound() async {
        fixture.protoc.locator.result = .success(ProtocFixtures.homebrew)
        await fixture.protoc.model.refresh()
        fixture.model.showSettings(.grpc)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.settingsSize)
    }

    func testSettingsGRPCMissing() async {
        await fixture.protoc.model.refresh()
        fixture.model.showSettings(.grpc)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.settingsSize)
    }

    func testSettingsGRPCInstalling() async {
        let downloading = ProtocInstallPhase.downloading(receivedBytes: 1_300_000, expectedBytes: 3_700_000)
        fixture.tearDown()
        fixture = AppFixture(protocInstaller: StubProtocInstaller(phases: [downloading]))
        await fixture.protoc.model.refresh()
        fixture.protoc.model.install()
        await waitUntil("the download phase") { fixture.protoc.model.installState == .installing(downloading) }
        fixture.model.showSettings(.grpc)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.settingsSize)

        fixture.protoc.model.cancelInstall()
        await waitUntil("the cancellation") { fixture.protoc.model.installState == .idle }
    }

    func testProjectSettingsProtoDefinitionsReady() throws {
        let settings = try protoDefinitionsSettings()

        assertBothAppearances(
            protoDefinitions(settings, status: .ready(serviceCount: 3, compiledAt: Date(timeIntervalSince1970: 1_700_000_000))),
            size: Self.protoDefinitionsSize
        )
    }

    func testProjectSettingsProtoDefinitionsDiagnostics() throws {
        let settings = try protoDefinitionsSettings()
        let diagnostics = [
            ProtocDiagnostic(file: "acme/v1/users.proto", line: 12, column: 3, message: "\"Userr\" is not defined."),
            ProtocDiagnostic(
                severity: .warning,
                file: "acme/v1/billing.proto",
                line: 4,
                column: 1,
                message: "Import \"google/protobuf/empty.proto\" is unused."
            )
        ]

        assertBothAppearances(protoDefinitions(settings, status: .failed(diagnostics)), size: Self.protoDefinitionsSize)
    }

    /// A saved configuration with a shared and a this-Mac root, an entry file, and a descriptor set.
    private func protoDefinitionsSettings() throws -> ProjectSettingsModel {
        let project = try SnapshotProject.make(in: fixture)
        let local = fixture.component.workspaceState.addLocalPath("/Users/shared/acme-protos", for: .protoRoots, in: project.id)
        try fixture.library.mutate(project.id) { document in
            document.grpc = ProjectGRPCConfiguration(
                protoRoots: [.relative("protos"), local],
                protoFiles: ["acme/v1/users.proto"],
                descriptorSets: [.relative("schema/billing.protoset")]
            )
        }
        return ProjectSettingsModel(projectID: project.id, app: fixture.model)
    }

    /// The sheet's proto sections alone: in the full sheet they sit below the fold of its fixed height.
    private func protoDefinitions(_ settings: ProjectSettingsModel, status: ProtoWorkspace.Status) -> some View {
        Form {
            ProjectSettingsProtoDefinitions(settings: settings, status: status)
        }
        .formStyle(.grouped)
    }
}
