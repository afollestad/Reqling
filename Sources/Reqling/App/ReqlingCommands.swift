import AppKit
import SwiftUI

/// Menu-bar commands; they dispatch through `AppModel`, so they work whatever has focus.
struct ReqlingCommands: Commands {
    let model: AppModel
    /// A focused body search field, which the Find menu steps through.
    @FocusedValue(\.bodySearch) private var focusedSearch

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(model.appInfo.name)") { AboutPanel.show() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Request") { model.newRequest() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Folder") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Project…") { model.sheet = .newProject }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Add Project Folder…") { model.openProjectFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Import Postman Collection…") { model.sheet = .importPostman }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { find(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { find(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            Divider()
            // ⌥Esc, F5, and ⌘P work too, unlisted: a menu item shows one shortcut, and ⌘P is File ▸ Print's.
            Button("Show Completions") { beepUnless(CodeTextView.showCompletions(in: NSApp.keyWindow)) }
                .keyboardShortcut(.space, modifiers: .control)
            Button("Show Parameter Hints") { beepUnless(CodeTextView.showParameterHints(in: NSApp.keyWindow)) }
                .keyboardShortcut(.space, modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            // Not ⌘F: that stays with the editors' own Find.
            Button("Filter Sidebar") { model.sidebar.requestFocus() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button(model.isInspectorShown && model.editor != nil ? "Hide Inspector" : "Show Inspector") { model.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.editor == nil)
        }
        CommandMenu("Request") {
            Button(model.editor?.sendTitle ?? "Send") { model.editor?.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.editor == nil)
            Button(model.editor?.cancelTitle ?? "Cancel") { model.editor?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.editor?.isSending != true)
            Divider()
            let batchTarget = model.batchTarget(for: model.selection)
            Button(model.batchRunTitle(for: batchTarget)) { model.openBatchRun(batchTarget) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!model.canRunBatch(batchTarget))
            Button("Stop Run") { model.stopBatchRun() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!model.batches.isRunning)
            Divider()
            // HTTP only: a gRPC call or WebSocket has no cURL form.
            Button("Copy as cURL") { model.editor?.asHTTP?.copyAsCurl() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.editor?.asHTTP.map { $0.isCopyingCurl } ?? true)
            Divider()
            Button(model.showsRunHistory ? "Hide Run History" : "Show Run History") { model.toggleRunHistory() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.editor == nil)
            Button(model.showsGraphQLSchema ? "Hide GraphQL Schema" : "Show GraphQL Schema") { model.toggleGraphQLSchema() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(model.editor?.asHTTP?.graphQL == nil)
            Divider()
            Button("Environments…") {
                if let project = model.activeProjectID {
                    model.sheet = .environments(project)
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.activeProjectID == nil)
        }
    }

    /// Editor commands act on the focused code editor; anywhere else there is nothing for them to do.
    private func beepUnless(_ handled: Bool) {
        if !handled {
            NSSound.beep()
        }
    }

    /// Finds in the focused body editor, response, or body search; anywhere else there is nothing to search in place.
    private func find(_ action: NSTextFinder.Action) {
        if let focusedSearch {
            focusedSearch.perform(action)
        } else if !CodeTextView.performFind(action, in: NSApp.keyWindow), !InPlaceFind.perform(action, in: NSApp.keyWindow) {
            NSSound.beep()
        }
    }
}
