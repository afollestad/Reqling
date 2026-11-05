#if DEBUG
import AppKit
import ReqlingKit
import SwiftUI

/// A launch into one of the website's screenshot states, read from `-DebugScreenshotScene <scene>` and
/// `-DebugScreenshotTheme light|dark` (`scripts/screenshots.sh` passes both). The app then runs over throwaway storage
/// seeded with `ScreenshotDemoProject`, never the developer's projects, Keychain, or Trash.
struct ScreenshotMode {
    /// `scripts/screenshots.sh` names each of these, so add a new one there too.
    enum Scene: String, CaseIterable {
        /// A GET with variables in its URL and parameters, and its JSON response as a tree.
        case request
        /// A POST's JSON body, and its response's timing waterfall.
        case body
        /// A bidirectional gRPC call's messages, and its timeline of what was sent and received.
        case grpc
        /// A GraphQL query checked against its schema file, and that schema in the inspector's browser.
        case graphql
    }

    let scene: Scene
    let theme: AppTheme

    /// `nil` for an ordinary launch. Read once, so `AppDI` and the window agree for the whole run; launch arguments
    /// land in `UserDefaults`' argument domain.
    static let current: ScreenshotMode? = {
        let defaults = UserDefaults.standard
        guard let scene = defaults.string(forKey: "DebugScreenshotScene").flatMap(Scene.init(rawValue:)) else {
            return nil
        }
        let theme = defaults.string(forKey: "DebugScreenshotTheme").flatMap(AppTheme.init(rawValue:)) ?? .light
        return ScreenshotMode(scene: scene, theme: theme)
    }()

    /// Builds the root component over freshly wiped screenshot storage and seeds it, so every launch of a scene shows
    /// exactly the same window. Runs before the window exists: `AppModel` restores the seeded selection as it is built.
    @MainActor
    func makeComponent(fileManager: FileManager = .default) -> AppComponent {
        let profile = AppStorageProfile.screenshots(fileManager: fileManager)
        let component = AppComponent(storageProfile: profile)
        component.settingsStore.update { settings in
            settings.theme = theme
            settings.checksForUpdatesAutomatically = false
        }
        do {
            try ScreenshotDemoProject.seed(scene, into: component)
        } catch {
            fatalError("Couldn't seed the screenshot demo project: \(error)")
        }
        return component
    }
}

/// Makes the window it sits in ignore the pointer, so a capture shows no hover effect wherever the pointer rests, and
/// a stray click lands on the window beneath rather than changing the scene.
struct ScreenshotWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScreenshotWindowAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ScreenshotWindowAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.ignoresMouseEvents = true
    }
}

extension AppStorageProfile {
    /// One fixed temporary root and defaults suite, wiped at every screenshot launch rather than at quit, since
    /// `scripts/screenshots.sh` ends each launch with a signal that skips `applicationWillTerminate`. Ephemeral, so the
    /// graph keeps secrets and the MCP token in memory, trashes into its own folder, and stays offline.
    static func screenshots(fileManager: FileManager = .default) -> AppStorageProfile {
        let suiteName = "com.afollestad.reqling.screenshots"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create the screenshot UserDefaults suite: \(suiteName)")
        }
        let profile = AppStorageProfile(
            applicationSupportDirectory: fileManager.temporaryDirectory.appendingPathComponent("ReqlingScreenshots", isDirectory: true),
            settingsDefaults: defaults,
            settingsDefaultsSuiteName: suiteName,
            isEphemeral: true
        )
        profile.cleanUp(fileManager: fileManager)
        return profile
    }
}
#endif
