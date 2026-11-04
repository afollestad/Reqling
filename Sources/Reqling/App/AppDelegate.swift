import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Starts the MCP server when Settings has it on. The root model exists by now, so tools can reach the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppDI.component.appModel
        AppDI.component.mcpServer.sync()
    }

    /// Asks before quitting would lose an edit that cannot be saved (`AppModel.confirmTermination`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDI.component.appModel.confirmTermination() ? .terminateNow : .terminateCancel
    }

    /// Saves edits still waiting on their autosave pause. Synchronous: the process can outlive no `Task` hop here.
    func applicationWillTerminate(_ notification: Notification) {
        AppDI.component.appModel.flushPendingEdits()
        AppDI.component.mcpServer.stopListening()
    }
}
