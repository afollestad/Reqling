import AppKit
import ReqlingKit
import SwiftUI

/// A multi-line code editor for request bodies. Read-only text, such as a response, goes in `CodeViewer`.
///
/// AppKit underneath (`CodeTextView`, an `NSTextView`): SwiftUI's `TextEditor` can neither color ranges as they are
/// typed nor draw `{{variable}}` pills with their tooltips and completion.
///
/// Text is re-highlighted as it changes; outside changes to it land through `CodeTextView.replaceText(with:)`, never as
/// undo steps.
///
/// It honors SwiftUI's `isEnabled`, which AppKit views never see on their own: a disabled editor stays selectable
/// but takes no edits.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: SyntaxLanguage = .plainText
    var placeholder = ""
    var tokenContext: TemplateTokenContext = .empty
    var showsTemplateTokens = true
    var accessibilityLabel: String
    /// Lets a surrounding view edit as the user, for actions like Beautify.
    var handle: CodeEditorHandle?
    /// Problems to underline; a set found in an older version of the text waits until it matches again.
    var diagnostics: CodeDiagnosticSet = .none
    /// Suggests completions and describes names under the pointer; held weakly, so its owner keeps it.
    var assistant: (any CodeEditorAssistant)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = CodeTextView.make(isSingleLine: false)
        textView.minSize = .zero
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.setInitialText(text)
        update(textView, in: scrollView, environment: context.environment)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? CodeTextView else {
            return
        }
        update(textView, in: scrollView, environment: context.environment)
    }

    private func update(_ textView: CodeTextView, in scrollView: NSScrollView, environment: EnvironmentValues) {
        let isEnabled = environment.isEnabled
        textView.isEditable = isEnabled
        textView.isSelectable = true
        scrollView.alphaValue = isEnabled ? 1 : CodeTextView.disabledAlpha
        textView.placeholder = placeholder
        textView.showsTemplateTokens = showsTemplateTokens
        handle?.textView = textView
        textView.tokenContext = tokenContext
        textView.accentColor = environment.appAccent
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.language = language
        textView.replaceText(with: text)
        // After the text, which the set is stamped against.
        textView.diagnostics = diagnostics
        if textView.assistance.assistant !== assistant {
            textView.assistance.assistant = assistant
            textView.dismissCompletions()
            textView.hideSignatureHelp()
            textView.hideHover()
            textView.updateHoverTracking()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: CodeTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        /// Skips a write the model already holds, so an edit that changes nothing never re-renders the parent.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, text.wrappedValue != textView.string else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}

/// A single-line field for URLs, header values, and other template text, with the editor's variable pills. AppKit
/// underneath (`SingleLineTextView`) for the same reason as `CodeEditor`: a SwiftUI `TextField` cannot draw the pills.
struct TemplateField: View {
    @Binding var text: String
    var placeholder = ""
    var tokenContext: TemplateTokenContext = .empty
    var accessibilityLabel: String
    var onSubmit: (() -> Void)?
    var onPaste: ((String) -> Bool)?

    @State private var isFocused = false
    @Environment(\.appAccent) private var accent

    var body: some View {
        SingleLineTextView(
            text: $text,
            placeholder: placeholder,
            tokenContext: tokenContext,
            accessibilityLabel: accessibilityLabel,
            onSubmit: onSubmit,
            onPaste: onPaste,
            onFocusChange: { isFocused = $0 }
        )
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                .strokeBorder(isFocused ? Color(nsColor: accent) : Color(nsColor: .separatorColor), lineWidth: isFocused ? 2 : 1)
        )
    }
}

private struct SingleLineTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var tokenContext: TemplateTokenContext
    var accessibilityLabel: String
    var onSubmit: (() -> Void)?
    var onPaste: ((String) -> Bool)?
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> CodeEditor.Coordinator {
        CodeEditor.Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = CodeTextView.make(isSingleLine: true)
        textView.minSize = NSSize(width: 0, height: 24)
        textView.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.setInitialText(text)
        update(textView, in: scrollView, isEnabled: context.environment.isEnabled, accent: context.environment.appAccent)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let textView = scrollView.documentView as? CodeTextView {
            update(textView, in: scrollView, isEnabled: context.environment.isEnabled, accent: context.environment.appAccent)
        }
    }

    private func update(_ textView: CodeTextView, in scrollView: NSScrollView, isEnabled: Bool, accent: NSColor) {
        textView.isEditable = isEnabled
        scrollView.alphaValue = isEnabled ? 1 : CodeTextView.disabledAlpha
        textView.placeholder = placeholder
        textView.tokenContext = tokenContext
        textView.accentColor = accent
        textView.onSubmit = onSubmit
        textView.onPaste = onPaste
        textView.onFocusChange = onFocusChange
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.replaceText(with: text)
    }
}

extension CodeTextView {
    /// How far a disabled editor fades, close to AppKit's disabled control text.
    static let disabledAlpha: CGFloat = 0.5
}
