import AppKit
import ReqlingKit
import SwiftUI

/// A multi-line code editor for request bodies, and a read-only viewer for responses.
///
/// Editable text is re-highlighted as it changes; outside changes to it land through `CodeTextView.replaceText(with:)`,
/// never as undo steps. Read-only text, which can be megabytes of response, is tokenized off the main actor above
/// `Coordinator.inlineColoringLimit` and colored in place.
///
/// It honors SwiftUI's `isEnabled`, which AppKit views never see on their own: a disabled editor stays selectable
/// but takes no edits.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: SyntaxLanguage = .plainText
    var isEditable = true
    var placeholder = ""
    var tokenContext: TemplateTokenContext = .empty
    var showsTemplateTokens = true
    var accessibilityLabel: String
    /// Lets a surrounding view edit as the user, for actions like Beautify.
    var handle: CodeEditorHandle?

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
        if isEditable {
            textView.setInitialText(text)
        }
        update(textView, in: scrollView, coordinator: context.coordinator, environment: context.environment)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? CodeTextView else {
            return
        }
        update(textView, in: scrollView, coordinator: context.coordinator, environment: context.environment)
    }

    private func update(_ textView: CodeTextView, in scrollView: NSScrollView, coordinator: Coordinator, environment: EnvironmentValues) {
        let isEnabled = environment.isEnabled
        textView.isPrecolored = !isEditable
        textView.isEditable = isEditable && isEnabled
        textView.isSelectable = true
        scrollView.alphaValue = isEnabled ? 1 : CodeTextView.disabledAlpha
        textView.placeholder = placeholder
        textView.showsTemplateTokens = showsTemplateTokens
        handle?.textView = textView
        textView.tokenContext = tokenContext
        textView.accentColor = environment.appAccent
        textView.setAccessibilityLabel(accessibilityLabel)
        if isEditable {
            textView.language = language
            textView.replaceText(with: text)
        } else {
            coordinator.showReadOnly(text, language: language, in: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: CodeTextView?
        private var shown: (text: String, language: SyntaxLanguage)?
        private var generation = 0

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

        /// Below this many UTF-16 units, coloring happens inline: it takes well under a frame and avoids a flash of
        /// plain text. Larger bodies are tokenized off the main actor.
        static let inlineColoringLimit = 100_000

        /// Colors read-only text; a newer text or language supersedes a styling pass still in flight.
        func showReadOnly(_ text: String, language: SyntaxLanguage, in textView: CodeTextView) {
            if let shown, shown.text == text, shown.language == language {
                return
            }
            shown = (text, language)
            generation += 1
            let font = textView.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            if language == .plainText {
                textView.textStorage?.setAttributedString(SyntaxPalette.attributedString(text, tokens: [], font: font))
            } else if (text as NSString).length <= Self.inlineColoringLimit {
                let tokens = SyntaxTokenizer.tokens(in: text, language: language)
                textView.textStorage?.setAttributedString(SyntaxPalette.attributedString(text, tokens: tokens, font: font))
            } else {
                textView.textStorage?.setAttributedString(SyntaxPalette.attributedString(text, tokens: [], font: font))
                colorInBackground(text, language: language, generation: generation, textView: textView)
            }
        }

        /// Colors the plain text already on screen in place once tokens arrive. Swapping in a new attributed string
        /// would replace every character, dropping the selection and scroll position the reader set meanwhile.
        private func colorInBackground(_ text: String, language: SyntaxLanguage, generation expected: Int, textView: CodeTextView) {
            Task { [weak self, weak textView] in
                let tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxTokenizer.tokens(in: text, language: language)
                }.value
                guard let self, self.generation == expected, let textView, let storage = textView.textStorage,
                      storage.length == (text as NSString).length else {
                    return
                }
                let selection = textView.selectedRanges
                let clipView = textView.enclosingScrollView?.contentView
                let origin = clipView?.bounds.origin
                SyntaxPalette.applyColors(tokens, to: storage)
                textView.selectedRanges = selection
                if let clipView, let origin, clipView.bounds.origin != origin {
                    clipView.scroll(to: origin)
                    textView.enclosingScrollView?.reflectScrolledClipView(clipView)
                }
            }
        }
    }
}

/// A single-line field for URLs, header values, and other template text, with the editor's variable pills.
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
