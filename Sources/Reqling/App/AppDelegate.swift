import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Starts update checks, the MCP server, and iCloud sync as Settings has them, and prunes the run history to its
    /// limits, which may have passed while Reqling was closed. The root model exists by now, so tools can reach the
    /// window, and every project's file choices are settled before sync can change one (`ProjectLifecycle`).
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDI.component.appModel.startUpdates()
        AppDI.component.mcpServer.sync()
        AppDI.component.runHistory.prune()
        if AppDI.component.librarySync != nil {
            // CloudKit pushes another Mac's changes; they're silent, so this asks the person nothing.
            NSApp.registerForRemoteNotifications()
        }
        AppDI.component.appModel.iCloud.start()
    }

    /// Applies what iCloud delivered while Reqling was in the background, and syncs.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppDI.component.appModel.iCloud.setActive(true)
    }

    /// Holds what iCloud delivers until Reqling comes back, so applying it never asks for the Keychain unseen.
    func applicationDidResignActive(_ notification: Notification) {
        AppDI.component.appModel.iCloud.setActive(false)
    }

    /// Asks before quitting would lose an edit that cannot be saved (`AppModel.confirmTermination`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDI.component.appModel.confirmTermination() ? .terminateNow : .terminateCancel
    }

    /// Saves edits still waiting on their autosave pause. Synchronous: the process can outlive no `Task` hop here.
    func applicationWillTerminate(_ notification: Notification) {
        AppDI.component.appModel.flushPendingEdits()
        AppDI.component.mcpServer.stopListening()
        // Open streams, calls, and connections would otherwise end unrecorded with the process.
        AppDI.component.requestRunner.recordLiveRuns()
        // Last, after anything above that might still record a run.
        AppDI.component.requestRunner.flushHistory()
        AppDI.component.appModel.iCloud.flush()
    }
}
