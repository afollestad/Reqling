import AppKit
import ReqlingKit

/// What each row reads as, and what its copy commands copy.
extension BodyTreeCoordinator {
    struct RowText {
        let text: NSAttributedString
        let accessibilityLabel: String
    }

    /// Long strings are cut in the row; Copy Value copies them whole.
    private static let displayLimit = 500

    func rowText(for item: BodyTreeItem) -> RowText {
        var parts = RowParts()
        switch (item.node, structure) {
        case (nil, _), (.document, _):
            parts.add("[\(item.range.lowerBound.formatted()) … \((item.range.upperBound - 1).formatted())]", .secondaryLabelColor)
            parts.label = "Items \(item.range.lowerBound) to \(item.range.upperBound - 1)"
        case (.json(let entry, let index), _):
            jsonRow(entry, item: item, index: index, into: &parts)
        case (.message(let message), _):
            messageRow(message, into: &parts)
        case (.xml(let node), .xml(let index)):
            xmlRow(index.nodes[node], node: node, index: index, into: &parts)
        default:
            break
        }
        return RowText(text: parts.text, accessibilityLabel: parts.label)
    }

    func value(of item: BodyTreeItem) -> String {
        switch (item.node, structure) {
        case (.message(let message), _):
            return message.event.json
        case (.json(let entry, let index), _):
            switch entry.kind {
            case .string:
                return index.string(entry.valueRange)
            case .object, .array:
                let slice = index.data[(index.data.startIndex + entry.valueRange.lowerBound)..<(index.data.startIndex + entry.valueRange.upperBound)]
                let pretty = (try? JSONFormatter.pretty(Data(slice))).flatMap { $0 }
                return pretty.flatMap { String(bytes: $0, encoding: .utf8) } ?? index.text(entry.valueRange)
            default:
                return index.text(entry.valueRange)
            }
        case (.xml(let node), .xml(let index)):
            return index.xmlText(of: node)
        default:
            return ""
        }
    }

    func key(of item: BodyTreeItem) -> String? {
        switch (item.node, structure) {
        case (.json(let entry, _), _):
            entry.key
        case (.xml(let node), .xml(let index)):
            index.nodes[node].name.isEmpty ? nil : index.nodes[node].name
        default:
            nil
        }
    }

    /// JSONPath for JSON, an XPath-like path for XML.
    func path(of item: BodyTreeItem) -> String {
        var components: [BodyTreePathComponent] = []
        var current: BodyTreeItem? = item
        while let node = current {
            if let component = pathComponent(of: node) {
                components.append(component)
            }
            current = node.parentNode
        }
        components.reverse()
        if case .xml = structure {
            return BodyTreePathComponent.xmlPath(components)
        }
        return BodyTreePathComponent.jsonPath(components)
    }

    private func pathComponent(of item: BodyTreeItem) -> BodyTreePathComponent? {
        switch (item.node, structure) {
        case (.json(let entry, _), _):
            if let key = entry.key {
                return .key(key)
            }
            // A document's top-level value is `$` itself; newline-delimited JSON numbers its values.
            return isSingleRoot(item) ? nil : .index(item.range.lowerBound)
        case (.xml(let node), .xml(let index)):
            let xmlNode = index.nodes[node]
            switch xmlNode.kind {
            case .element:
                return .xml(name: xmlNode.name, position: index.position(of: node), isAttribute: false)
            case .attribute:
                return .xml(name: xmlNode.name, position: nil, isAttribute: true)
            case .text, .cdata:
                return .key("text()")
            case .comment:
                return .key("comment()")
            }
        default:
            return nil
        }
    }

    private func jsonRow(_ entry: JSONEntry, item: BodyTreeItem, index: JSONStructureIndex, into parts: inout RowParts) {
        var labelKey = ""
        if let key = entry.key {
            parts.add("\"\(key)\"", SyntaxPalette.property)
            parts.add(": ", SyntaxPalette.symbol)
            labelKey = key
        } else if !isSingleRoot(item) {
            parts.add("\(item.range.lowerBound)", .secondaryLabelColor)
            parts.add(": ", SyntaxPalette.symbol)
            labelKey = "Item \(item.range.lowerBound)"
        }
        let description: String
        switch entry.kind {
        case .object:
            description = entry.childCount == 0 ? "{}" : "{ \(Self.count(entry.childCount, "key")) }"
            parts.add(description, .secondaryLabelColor)
            parts.label = [labelKey, "object", Self.count(entry.childCount, "key")].filter { !$0.isEmpty }.joined(separator: ", ")
            return
        case .array:
            description = entry.childCount == 0 ? "[]" : "[ \(Self.count(entry.childCount, "item")) ]"
            parts.add(description, .secondaryLabelColor)
            parts.label = [labelKey, "array", Self.count(entry.childCount, "item")].filter { !$0.isEmpty }.joined(separator: ", ")
            return
        case .string:
            let text = Self.oneLine(index.string(entry.valueRange, limit: Self.displayLimit * 4), limit: Self.displayLimit)
            parts.add("\"\(text)\"", SyntaxPalette.string)
            description = text
        case .number:
            description = index.text(entry.valueRange)
            parts.add(description, SyntaxPalette.number)
        case .bool, .null:
            description = index.text(entry.valueRange)
            parts.add(description, SyntaxPalette.keyword)
        }
        parts.label = [labelKey, "\(entry.kind)", description].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A message's header: which way it went, when, its size, fields the schema lacks, and why it has no fields when it
    /// doesn't parse.
    private func messageRow(_ message: MessageTimeline.Message, into parts: inout RowParts) {
        let event = message.event
        let isSent = event.direction == .sent
        parts.add(isSent ? "↑ Sent" : "↓ Received", isSent ? accent : .systemTeal)
        let offset = ResponseStatusBar.duration(event.offset)
        let size = ByteCountFormatter.string(fromByteCount: Int64(event.byteCount), countStyle: .binary)
        parts.add("  +\(offset) · \(size)", .secondaryLabelColor)
        var label = "\(isSent ? "Sent" : "Received") message, \(offset) into the call, \(size)"
        if event.unknownFieldCount > 0 {
            let unknown = event.unknownFieldCount == 1 ? "1 unknown field" : "\(event.unknownFieldCount) unknown fields"
            parts.add("  ⚠ \(unknown)", .systemOrange)
            label += ", \(unknown)"
        }
        if message.index == nil {
            parts.add("  Not shown as a tree; switch to Text to read it", .secondaryLabelColor)
            label += ", not shown as a tree"
        }
        parts.label = label
    }

    private func xmlRow(_ node: XMLStructureIndex.Node, node position: Int, index: XMLStructureIndex, into parts: inout RowParts) {
        switch node.kind {
        case .element:
            parts.add("<\(node.name)>", SyntaxPalette.keyword)
            // An element holding only text shows it inline; listing children only then keeps a huge element's row cheap.
            let children = node.childCount == 1 ? index.children(of: position) : []
            if children.count == 1, index.nodes[children[0]].kind == .text {
                parts.add(" " + Self.oneLine(index.nodes[children[0]].value, limit: Self.displayLimit), SyntaxPalette.base)
            }
            parts.label = "\(node.name), element, \(Self.count(Int(node.childCount), "child", plural: "children"))"
        case .attribute:
            parts.add("@\(node.name)", SyntaxPalette.property)
            parts.add(" = ", SyntaxPalette.symbol)
            parts.add("\"\(Self.oneLine(node.value, limit: Self.displayLimit))\"", SyntaxPalette.string)
            parts.label = "\(node.name), attribute, \(node.value)"
        case .text:
            parts.add(Self.oneLine(node.value, limit: Self.displayLimit), SyntaxPalette.base)
            parts.label = "text, \(node.value)"
        case .cdata:
            parts.add("CDATA ", .secondaryLabelColor)
            parts.add(Self.oneLine(node.value, limit: Self.displayLimit), SyntaxPalette.string)
            parts.label = "CDATA, \(node.value)"
        case .comment:
            parts.add("<!-- \(Self.oneLine(node.value, limit: Self.displayLimit)) -->", SyntaxPalette.comment)
            parts.label = "comment, \(node.value)"
        }
    }

    private static func count(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? noun : plural ?? noun + "s")"
    }

    /// `text` on one row: line breaks shown as ↵, cut with an ellipsis past `limit` characters.
    private static func oneLine(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }
}

/// A row's text built from colored runs in the editors' monospaced font.
@MainActor
private struct RowParts {
    private(set) var text = NSMutableAttributedString()
    var label = ""

    mutating func add(_ string: String, _ color: NSColor) {
        text.append(NSAttributedString(string: string, attributes: [.font: CodeViewerMetrics.standard.font, .foregroundColor: color]))
    }
}
