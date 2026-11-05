import AppKit

/// Credits are the only extra content the standard About panel accepts, so the byline and links go there; the panel
/// still reads the name, icon, version, and copyright from Info.plist.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraphStyle
        ]
        let credits = NSMutableAttributedString(string: "\nMade with ❤️ by Aidan Follestad\n\n", attributes: attributes)
        credits.append(link("Website", to: "https://reqling.af.codes", attributes: attributes))
        credits.append(NSAttributedString(string: " | ", attributes: attributes))
        credits.append(link("Ko-fi", to: "https://ko-fi.com/aidan1995", attributes: attributes))
        return credits
    }

    private static func link(_ label: String, to urlString: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = attributes
        if let url = URL(string: urlString) {
            attributes[.link] = url
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: label, attributes: attributes)
    }
}
