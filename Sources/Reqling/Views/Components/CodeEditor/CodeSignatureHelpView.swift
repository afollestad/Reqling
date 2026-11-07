import SwiftUI

/// Parameter hints: the signature of the method being called with the parameter being typed in the accent color, what
/// that parameter is, and what the method does. Styled as `CodeHoverCard` is, as the two are seen together.
struct CodeSignatureHelpView: View {
    let help: CodeSignatureHelp
    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(signature)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
            if let parameter = help.active, let summary = parameter.summary {
                Text(Self.describe(parameter.name, summary))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = help.summary {
                Divider()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: CodeHoverCard.maxWidth, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// `name(first: string, second?: object): type`, the active parameter set apart.
    private var signature: AttributedString {
        var text = AttributedString("\(help.name)(")
        for (index, parameter) in help.parameters.enumerated() {
            if index > 0 {
                text += AttributedString(", ")
            }
            var label = AttributedString(parameter.label)
            if index == help.activeParameter {
                label.font = .system(.callout, design: .monospaced).weight(.semibold)
                label.foregroundColor = Color(nsColor: accent)
            }
            text += label
        }
        text += AttributedString("): \(help.returnType)")
        return text
    }

    /// `name — what it is`, the name in code type.
    private static func describe(_ name: String, _ summary: String) -> AttributedString {
        var code = AttributedString(name)
        code.font = .system(.callout, design: .monospaced).weight(.semibold)
        return code + AttributedString(" — \(summary)")
    }
}
