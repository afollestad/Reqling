import Foundation
internal import ReqlingYAML

/// A value inside one of an import's documents, with the document it sits in, so a `$ref` inside it resolves against
/// the right base.
struct OpenAPINode {
    var value: YAMLValue
    var document: URL

    subscript(key: String) -> OpenAPINode? {
        value[key].map { OpenAPINode(value: $0, document: document) }
    }

    /// A list's items, or a mapping's values, each in this node's document.
    var elements: [OpenAPINode] {
        (value.array ?? value.members?.map(\.value) ?? []).map { OpenAPINode(value: $0, document: document) }
    }

    /// A mapping's members as nodes, in order.
    var members: [(key: String, node: OpenAPINode)] {
        (value.members ?? []).map { ($0.key, OpenAPINode(value: $0.value, document: document)) }
    }
}

/// How `$ref`s name documents and the values in them: a URL resolved against the referring document's base (its
/// `$self`, in 3.2, or where it was read from), then an RFC 6901 pointer in the fragment. `$id` rebasing and plain-name
/// `$anchor` fragments aren't followed; a reference that needs one becomes a note.
enum OpenAPIReferences {
    /// A document's URL without its fragment, which is how loaded documents are keyed.
    static func documentKey(_ url: URL) -> URL {
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let key = components?.url ?? url
        return key.isFileURL ? key.standardizedFileURL : key.standardized
    }

    /// What a document's relative references resolve against: its 3.2 `$self`, or where it was read from.
    static func base(of document: YAMLValue, retrievedFrom url: URL) -> URL {
        document["$self"]?.string.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
    }

    /// The document a reference names, and the pointer within it; `nil` for a reference that isn't a URL.
    static func split(_ reference: String, base: URL, document: URL) -> (document: URL, pointer: String)? {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        let pointer = fragment.removingPercentEncoding ?? fragment
        guard let path = parts.first, !path.isEmpty else {
            return (document, pointer)
        }
        let text = String(path)
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlPathAllowed)) ?? text
        guard let url = URL(string: text, relativeTo: base) ?? URL(string: encoded, relativeTo: base) else {
            return nil
        }
        return (documentKey(url), pointer)
    }

    /// The value at an RFC 6901 pointer (`/components/schemas/Pet`, `~1` for `/` and `~0` for `~`), or `nil`.
    static func value(at pointer: String, in document: YAMLValue) -> YAMLValue? {
        guard !pointer.isEmpty else {
            return document
        }
        guard pointer.hasPrefix("/") else {
            return nil
        }
        var current = document
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let members = current.members, let member = members.first(where: { $0.key == key }) {
                current = member.value
            } else if let items = current.array, let position = Int(key), items.indices.contains(position) {
                current = items[position]
            } else {
                return nil
            }
        }
        return current
    }

    /// The other documents a document's `$ref`s name, each once.
    static func documentTargets(in document: YAMLValue, base: URL) -> [URL] {
        var targets: [URL] = []
        var own = Set<URL>()
        own.insert(documentKey(base))
        visit(document) { key, value in
            guard key == "$ref", let reference = value.string, let target = split(reference, base: base, document: base)?.document,
                  !own.contains(target), !targets.contains(target) else {
                return
            }
            targets.append(target)
        }
        return targets
    }

    /// The URLs examples give as `externalValue`.
    static func externalValues(in document: YAMLValue, base: URL) -> [URL] {
        var targets: [URL] = []
        visit(document) { key, value in
            if key == "externalValue", let text = value.string, let url = URL(string: text, relativeTo: base)?.absoluteURL {
                targets.append(url)
            }
        }
        return targets
    }

    /// Every member of every mapping, depth-first.
    private static func visit(_ value: YAMLValue, _ body: (String, YAMLValue) -> Void) {
        switch value {
        case .object(let members):
            for member in members {
                body(member.key, member.value)
                visit(member.value, body)
            }
        case .array(let values):
            for value in values {
                visit(value, body)
            }
        default:
            break
        }
    }
}

/// Resolves `$ref`s across an import's loaded documents, following chains.
struct OpenAPIResolver {
    static let maximumHops = 32

    let source: OpenAPISource

    /// The node a reference leads to, through any chain of references; the node itself when it isn't one. Fails with
    /// why: a document that didn't load, a pointer to nothing, an anchor, or a cycle.
    func resolve(_ node: OpenAPINode) -> Result<OpenAPINode, OpenAPIReferenceFailure> {
        var current = node
        var seen: Set<String> = []
        for _ in 0..<Self.maximumHops {
            guard let reference = current.value["$ref"]?.string else {
                return .success(current)
            }
            guard seen.insert("\(current.document.absoluteString)\u{0}\(reference)").inserted else {
                return .failure(OpenAPIReferenceFailure(reference: reference, reason: "It leads back to itself."))
            }
            switch target(of: reference, from: current.document) {
            case .success(let target):
                current = target
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(OpenAPIReferenceFailure(reference: node.value["$ref"]?.string ?? "", reason: "It goes through too many references."))
    }

    /// What a reference names, document and pointer, however it's written: `#/a` and `api.yaml#/a` inside `api.yaml`
    /// are the same target. `nil` for one that isn't a URL.
    func targetKey(of reference: String, from document: URL) -> String? {
        let base = source.documents[document].map { OpenAPIReferences.base(of: $0, retrievedFrom: document) } ?? document
        return OpenAPIReferences.split(reference, base: base, document: document).map { "\($0.document.absoluteString)#\($0.pointer)" }
    }

    private func target(of reference: String, from document: URL) -> Result<OpenAPINode, OpenAPIReferenceFailure> {
        func fail(_ reason: String) -> Result<OpenAPINode, OpenAPIReferenceFailure> {
            .failure(OpenAPIReferenceFailure(reference: reference, reason: reason))
        }
        guard let containing = source.documents[document] else {
            return fail("Its document wasn't loaded.")
        }
        let base = OpenAPIReferences.base(of: containing, retrievedFrom: document)
        guard let (targetDocument, pointer) = OpenAPIReferences.split(reference, base: base, document: document) else {
            return fail("It isn't a reference Reqling can follow.")
        }
        guard let loaded = source.documents[targetDocument] else {
            return fail(source.failures[targetDocument] ?? "Its document wasn't loaded.")
        }
        guard pointer.isEmpty || pointer.hasPrefix("/") else {
            return fail("It names an anchor (#\(pointer)), which Reqling doesn't follow.")
        }
        guard let value = OpenAPIReferences.value(at: pointer, in: loaded) else {
            return fail("It names nothing in its document.")
        }
        return .success(OpenAPINode(value: value, document: targetDocument))
    }
}

struct OpenAPIReferenceFailure: Error, Hashable {
    let reference: String
    let reason: String

    var message: String {
        "Its reference “\(reference)” couldn't be followed. \(reason)"
    }
}
