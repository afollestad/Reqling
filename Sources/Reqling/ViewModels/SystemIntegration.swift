import AppKit
import ReqlingKit
import UniformTypeIdentifiers

/// The AppKit services view models reach for. A protocol so tests never open a panel, touch the pasteboard, or
/// reveal anything in Finder.
@MainActor
protocol SystemIntegration {
    func chooseDirectory(prompt: String) -> URL?
    func chooseFile(prompt: String, allowedTypes: [UTType]) -> URL?
    func chooseSaveLocation(suggestedName: String) -> URL?
    func reveal(_ url: URL)
    func copyToPasteboard(_ string: String)
    /// Asks how to store a file outside the project's folder and repository; `nil` means cancelled.
    func choosePathSharing(for url: URL) -> PathSharing?
    /// Asks whether to quit even though unsaved edits would be lost; true means quit.
    func confirmQuitDiscardingUnsavedChanges() -> Bool
    /// Activates Reqling and brings its window forward, for an agent showing the user something.
    func bringToFront()
}

enum PathSharing {
    /// A path relative to the project folder, shared with everyone who has the project.
    case shared
    /// An absolute path remembered on this Mac only.
    case thisMacOnly
}

struct AppKitSystemIntegration: SystemIntegration {
    func bringToFront() {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && !$0.isMiniaturized }?.makeKeyAndOrderFront(nil)
    }

    func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFile(prompt: String, allowedTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func choosePathSharing(for url: URL) -> PathSharing? {
        let alert = NSAlert()
        alert.messageText = "How should Reqling remember “\(url.lastPathComponent)”?"
        alert.informativeText = """
            This file is outside the project's folder and repository. A shared path is stored relative to the project, \
            so it works for everyone who has the same folder layout. A this-Mac-only path is never written to the project.
            """
        alert.addButton(withTitle: "Shared Path")
        alert.addButton(withTitle: "This Mac Only")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .shared
        case .alertSecondButtonReturn: return .thisMacOnly
        default: return nil
        }
    }

    func confirmQuitDiscardingUnsavedChanges() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit and discard unsaved changes?"
        alert.informativeText = "A project with unsaved edits isn't available, so they can't be saved. They're lost if you quit now."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
