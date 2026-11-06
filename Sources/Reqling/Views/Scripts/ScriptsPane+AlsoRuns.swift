import SwiftUI

/// The levels whose scripts run first, outermost first, each opening its scripts.
struct ScriptsPaneAlsoRuns: View {
    let links: [ScriptsChainLink]
    let open: (ScriptsChainLink) -> Void
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            Text("Runs after:")
                .foregroundStyle(.secondary)
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Image(systemName: "chevron.forward")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button(link.title) { open(link) }
                    // In the accent, as the app's other in-text links are; `.link` draws the system blue.
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: accent))
                    .help(link.owner == .project ? "Show the project's scripts" : "Show the scripts of folder “\(link.title)”")
            }
        }
        .font(.callout)
        .lineLimit(1)
    }
}
