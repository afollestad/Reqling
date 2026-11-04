import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    /// Off, with the token loaded (masked) and the setup commands; a running server's port is random in tests.
    func testSettingsMCP() {
        fixture.model.mcpSettings.loadToken()
        fixture.model.showSettings(.mcp)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: CGSize(width: 900, height: 780))
    }
}
