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
        /// A GET with a path variable and variables in its URL and parameters, and its JSON response as a tree.
        case request
        /// A bidirectional gRPC call's messages, and its timeline of what was sent and received.
        case grpc
        /// A GraphQL query checked against its schema file, and that schema in the inspector's browser.
        case graphql
        /// A GET whose response is an event stream, and its events as a tree.
        case events
        /// A live WebSocket connection (`ScreenshotLiveChat`): its composer, saved messages, and timeline both ways.
        case websocket
        /// A POST's post-response script (`ScreenshotScripts`), and its run's tests, one failing, and console.
        case scripts
        /// The Users folder after a run from a data file (`ScreenshotBatchRun`): each request's badge, one failing, and
        /// the run's bar at the sidebar's foot.
        case batch
    }

    let scene: Scene
    let theme: AppTheme

    /// The `websocket` scene's chat, kept for the whole run so its connection stays open until the capture.
    @MainActor private static var liveChat: ScreenshotLiveChat?
    /// Throws away every key press. The copy takes focus for each capture, so typing meant for another app would
    /// otherwise land in the sidebar, selecting another row or starting a rename. AppKit doesn't document the order
    /// monitors run in, so this one is installed before any view exists to install its own.
    @MainActor private static var keyMonitor: Any?

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
        Self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in nil }
        let profile = AppStorageProfile.screenshots(fileManager: fileManager)
        let component = AppComponent(storageProfile: profile)
        component.settingsStore.update { settings in
            settings.theme = theme
            settings.checksForUpdatesAutomatically = false
        }
        do {
            Self.liveChat = try ScreenshotDemoProject.seed(scene, into: component)
        } catch {
            fatalError("Couldn't seed the screenshot demo project: \(error)")
        }
        if let script = Self.liveChat?.script {
            Task {
                do {
                    try await script.value
                } catch {
                    fatalError("Couldn't run the screenshot chat: \(error)")
                }
            }
        }
        return component
    }
}

/// Makes the window it sits in ignore the pointer, so a capture shows no hover effect wherever the pointer rests, and
/// a stray click lands on the window beneath rather than changing the scene. That click takes focus from the copy,
/// which `scripts/screenshots.sh` then brings back to the front.
struct ScreenshotWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScreenshotWindowAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Runs `focus` a turn after each time the window it sits in becomes key, for the sidebar to take the keyboard, so the
/// selected row shows the fill a click leaves and no field shows a caret. The window hands its first text field the
/// keyboard as it appears, so waiting a turn comes after that; acting on every activation covers `scripts/screenshots.sh`
/// bringing the copy back to the front.
struct ScreenshotSidebarFocus: NSViewRepresentable {
    let focus: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScreenshotKeyWindowView()
        view.onBecomeKey = focus
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScreenshotKeyWindowView)?.onBecomeKey = focus
    }
}

private final class ScreenshotWindowAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.ignoresMouseEvents = true
    }
}

private final class ScreenshotKeyWindowView: NSView {
    var onBecomeKey: (@MainActor () -> Void)?
    private var windowObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObserver.map(NotificationCenter.default.removeObserver)
        windowObserver = nil
        guard let window else {
            return
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.becameKey()
            }
        }
        if window.isKeyWindow {
            becameKey()
        }
    }

    private func becameKey() {
        Task { @MainActor [weak self] in
            self?.onBecomeKey?()
        }
    }
}

extension AppStorageProfile {
    /// Preferences in memory, and one fixed temporary root, wiped at every screenshot launch rather than at quit, since
    /// `scripts/screenshots.sh` ends each launch with a signal that skips `applicationWillTerminate`. Ephemeral, so the
    /// graph keeps secrets and the MCP token in memory, trashes into its own folder, and stays offline.
    static func screenshots(fileManager: FileManager = .default) -> AppStorageProfile {
        let profile = AppStorageProfile(
            applicationSupportDirectory: fileManager.temporaryDirectory.appendingPathComponent("ReqlingScreenshots", isDirectory: true),
            preferences: MemoryPreferences(),
            isEphemeral: true
        )
        profile.cleanUp(fileManager: fileManager)
        return profile
    }
}
#endif
