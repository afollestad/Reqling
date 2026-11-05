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
            // An open gRPC stream takes ⌘Return as its next message rather than a restarted call.
            Button(model.editor?.asGRPC?.isStreamOpen == true ? "Send Message" : "Send") { model.editor?.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.editor == nil)
            Button("Cancel") { model.editor?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.editor?.isSending != true)
            Divider()
            // HTTP only: a gRPC call has no cURL form.
            Button("Copy as cURL") { model.editor?.asHTTP?.copyAsCurl() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.editor?.asHTTP == nil)
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

    /// Finds in the focused body editor, response, or body search; anywhere else there is nothing to search in place.
    private func find(_ action: NSTextFinder.Action) {
        if let focusedSearch {
            focusedSearch.perform(action)
        } else if !CodeTextView.performFind(action, in: NSApp.keyWindow), !InPlaceFind.perform(action, in: NSApp.keyWindow) {
            NSSound.beep()
        }
    }
}
