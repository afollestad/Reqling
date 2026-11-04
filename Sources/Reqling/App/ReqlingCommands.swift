import AppKit
import SwiftUI

/// Menu-bar commands; they dispatch through `AppModel`, so they work whatever has focus.
struct ReqlingCommands: Commands {
    let model: AppModel

    var body: some Commands {
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
        }
        CommandMenu("Request") {
            Button("Send") { model.editor?.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.editor == nil)
            Button("Cancel") { model.editor?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.editor?.isSending != true)
            Divider()
            Button("Copy as cURL") { model.editor?.copyAsCurl() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.editor == nil)
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

    /// Finds in the focused body or response; anywhere else there is nothing to search in place.
    private func find(_ action: NSTextFinder.Action) {
        if !CodeTextView.performFind(action, in: NSApp.keyWindow) {
            NSSound.beep()
        }
    }
}
