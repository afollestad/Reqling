import Foundation

/// An XML document as compact nodes for Tree mode: elements, their attributes (by name, as `XMLParser` reports them
/// unordered), non-blank text, CDATA, and comments. Built off the main actor by `XMLParser`, which streams and never
/// resolves external entities here.
public struct XMLStructureIndex: Sendable {
    public enum NodeKind: Hashable, Sendable {
        case element
        case attribute
        case text
        case cdata
        case comment
    }

    public struct Node: Hashable, Sendable {
        public let kind: NodeKind
        /// An element's or attribute's name; empty for text, CDATA, and comments.
        public let name: String
        /// An attribute's value, or the text, CDATA, or comment; empty for elements.
        public let value: String
        public let parent: Int32
        /// Its position among its parent's children.
        public let indexInParent: Int32
        public fileprivate(set) var childCount: Int32 = 0
        fileprivate(set) var firstChild: Int32 = -1
        fileprivate(set) var nextSibling: Int32 = -1
    }

    public let id = UUID()
    public let nodes: [Node]
    /// The top-level nodes: the root element, and any comments around it.
    public let roots: [Int]

    /// More nodes than this and the tree is not worth its memory; Raw still shows the text.
    public static let nodeLimit = 2_000_000

    /// Indexes `data`. With `allowsTruncation`, for a body known to be cut short, a parse that fails keeps the nodes
    /// read before it.
    public static func build(_ data: Data, allowsTruncation: Bool = false) throws(XMLIndexError) -> XMLStructureIndex {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        let succeeded = parser.parse()
        if builder.isCancelled {
            throw .cancelled
        }
        if builder.isTooLarge {
            throw .tooLarge
        }
        if !succeeded, allowsTruncation, !builder.roots.isEmpty {
            return XMLStructureIndex(nodes: builder.nodes, roots: builder.roots)
        }
        guard succeeded, parser.parserError == nil else {
            let message = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "The XML is not well-formed."
            throw .syntax(message: message, line: parser.lineNumber, column: parser.columnNumber)
        }
        return XMLStructureIndex(nodes: builder.nodes, roots: builder.roots)
    }

    public func children(of node: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(Int(nodes[node].childCount))
        var child = Int(nodes[node].firstChild)
        while child >= 0 {
            result.append(child)
            child = Int(nodes[child].nextSibling)
        }
        return result
    }

    /// The node's position among its parent's children of the same kind and name, from 1, for an XPath-like path;
    /// `nil` when it is the only one, which a path leaves unnumbered.
    public func position(of node: Int) -> Int? {
        let target = nodes[node]
        let siblings = (target.parent >= 0 ? children(of: Int(target.parent)) : roots)
            .filter { nodes[$0].kind == target.kind && nodes[$0].name == target.name }
        return siblings.count > 1 ? (siblings.firstIndex(of: node) ?? 0) + 1 : nil
    }

    /// What Copy Value copies: an element as XML, rebuilt from its nodes since the parser keeps no source offsets, or
    /// any other node's value as it reads.
    public func xmlText(of node: Int) -> String {
        guard nodes[node].kind == .element else {
            return nodes[node].value
        }
        var output = ""
        var stack: [(node: Int, isClosing: Bool)] = [(node, false)]
        while let (current, isClosing) = stack.popLast() {
            let item = nodes[current]
            switch item.kind {
            case .element where isClosing:
                output += "</\(item.name)>"
            case .element:
                let children = children(of: current)
                let attributes = children.filter { nodes[$0].kind == .attribute }
                let content = children.filter { nodes[$0].kind != .attribute }
                output += "<\(item.name)" + attributes.map { " \(nodes[$0].name)=\"\(Self.escape(nodes[$0].value, quotes: true))\"" }.joined()
                guard !content.isEmpty else {
                    output += "/>"
                    continue
                }
                output += ">"
                stack.append((current, true))
                stack.append(contentsOf: content.reversed().map { ($0, false) })
            case .text:
                output += Self.escape(item.value, quotes: false)
            case .cdata:
                output += "<![CDATA[\(item.value)]]>"
            case .comment:
                output += "<!--\(item.value)-->"
            case .attribute:
                break
            }
        }
        return output
    }

    private static func escape(_ text: String, quotes: Bool) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quotes {
            escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return escaped
    }

    func find(_ query: String, limit: Int) throws(CancellationError) -> BodyTreeSearchResult {
        let query = TreeQuery(query)
        var matches: [BodyTreeMatch] = []
        for (index, node) in nodes.enumerated() where matches.count < limit {
            if index.isMultiple(of: 65_536), Task.isCancelled {
                throw CancellationError()
            }
            if query.matches(node.name) || query.matches(node.value) {
                matches.append(BodyTreeMatch(path: path(of: index)))
            }
        }
        return BodyTreeSearchResult(matches: matches, isTruncated: matches.count >= limit)
    }

    /// The child index at each level from the top-level node down to `node`.
    private func path(of node: Int) -> [Int] {
        var path: [Int] = []
        var current = node
        while nodes[current].parent >= 0 {
            path.append(Int(nodes[current].indexInParent))
            current = Int(nodes[current].parent)
        }
        path.append(roots.firstIndex(of: current) ?? 0)
        return path.reversed()
    }
}

public enum XMLIndexError: Error, Hashable, Sendable {
    case syntax(message: String, line: Int, column: Int)
    case tooLarge
    case cancelled
}

/// `XMLParser`'s delegate, linking nodes as they stream in. Text is gathered until the next tag, since the parser
/// may report one run of text in pieces, and kept only when it isn't all whitespace.
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var nodes: [XMLStructureIndex.Node] = []
    var roots: [Int] = []
    var isCancelled = false
    var isTooLarge = false
    private var open: [Int] = []
    private var lastChild: [Int: Int] = [:]
    private var pendingText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        flushText()
        guard let element = add(.element, name: elementName, value: "", parser: parser) else {
            return
        }
        open.append(element)
        for name in attributeDict.keys.sorted() {
            _ = add(.attribute, name: name, value: attributeDict[name] ?? "", parser: parser)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        flushText()
        if let element = open.popLast() {
            lastChild[element] = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        pendingText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        flushText()
        _ = add(.cdata, name: "", value: String(bytes: CDATABlock, encoding: .utf8) ?? "", parser: parser)
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        flushText()
        _ = add(.comment, name: "", value: comment.trimmingCharacters(in: .whitespacesAndNewlines), parser: parser)
    }

    private func flushText() {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        if !text.isEmpty, !open.isEmpty {
            _ = add(.text, name: "", value: text, parser: nil)
        }
    }

    /// Appends a node under the open element, or at the top level; stops the parse past the limit or once cancelled.
    private func add(_ kind: XMLStructureIndex.NodeKind, name: String, value: String, parser: XMLParser?) -> Int? {
        guard nodes.count < XMLStructureIndex.nodeLimit else {
            isTooLarge = true
            parser?.abortParsing()
            return nil
        }
        if nodes.count.isMultiple(of: 65_536), Task.isCancelled {
            isCancelled = true
            parser?.abortParsing()
            return nil
        }
        let index = nodes.count
        let parent = open.last ?? -1
        let position = parent >= 0 ? nodes[parent].childCount : Int32(roots.count)
        nodes.append(XMLStructureIndex.Node(kind: kind, name: name, value: value, parent: Int32(parent), indexInParent: position))
        if parent >= 0 {
            nodes[parent].childCount += 1
            if let previous = lastChild[parent] {
                nodes[previous].nextSibling = Int32(index)
            } else {
                nodes[parent].firstChild = Int32(index)
            }
            lastChild[parent] = index
        } else {
            roots.append(index)
        }
        return index
    }
}
