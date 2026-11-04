import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Asks before quitting would lose an edit that cannot be saved (`AppModel.confirmTermination`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDI.component.appModel.confirmTermination() ? .terminateNow : .terminateCancel
    }

    /// Saves edits still waiting on their autosave pause. Synchronous: the process can outlive no `Task` hop here.
    func applicationWillTerminate(_ notification: Notification) {
        AppDI.component.appModel.flushPendingEdits()
    }
}
