import Foundation
@_implementationOnly import Yams

/// Reads YAML through Yams (libyaml) into `YAMLValue`s. Plain scalars are typed by YAML 1.2's core schema
/// (`YAMLScalars`) rather than Yams' YAML 1.1 defaults, which read `no`, `on`, and `012` as a boolean, a boolean, and an
/// octal number; JSON is YAML 1.2, so JSON text reads as JSON means it.
public enum YAML {
    /// One document's data; `null` for text with none. Throws when the text holds more than one document.
    ///
    /// `maximumNodes` bounds the values aliases expand to, against an alias bomb whose text is tiny; by default it's
    /// generous for any document written out in full.
    public static func parse(_ text: String, maximumNodes: Int? = nil) throws(YAMLError) -> YAMLValue {
        let documents = try parseAll(text, maximumNodes: maximumNodes)
        guard documents.count <= 1 else {
            throw YAMLError(message: "It holds \(documents.count) documents where one was expected.")
        }
        return documents.first ?? .null
    }

    /// `data` read as UTF-8, a leading byte order mark dropped.
    public static func parse(_ data: Data, maximumNodes: Int? = nil) throws(YAMLError) -> YAMLValue {
        try parse(try text(data), maximumNodes: maximumNodes)
    }

    /// Every document in a stream, in order, as a response of several `---` documents holds.
    public static func parseAll(_ text: String, maximumNodes: Int? = nil) throws(YAMLError) -> [YAMLValue] {
        var converter = YAMLConverter(budget: maximumNodes ?? max(1_000_000, text.utf8.count * 2))
        var documents: [YAMLValue] = []
        do {
            let parser = try Parser(yaml: text, resolver: YAMLScalars.resolver, encoding: .utf8)
            while let node = try parser.nextRoot() {
                documents.append(try converter.value(node))
            }
        } catch let error as YAMLError {
            throw error
        } catch let error as YamlError {
            throw YAMLError(error, in: text)
        } catch {
            throw YAMLError(message: error.localizedDescription)
        }
        return documents
    }

    public static func parseAll(_ data: Data, maximumNodes: Int? = nil) throws(YAMLError) -> [YAMLValue] {
        try parseAll(try text(data), maximumNodes: maximumNodes)
    }

    private static func text(_ data: Data) throws(YAMLError) -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            throw YAMLError(message: "It isn't UTF-8 text.")
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }
}

/// Yams' composed nodes to `YAMLValue`s. Yams hands an alias back as a copy of what it names, so a few lines of aliases
/// can stand for billions of values; `budget` counts the values made and stops there.
private struct YAMLConverter {
    var budget: Int

    mutating func value(_ node: Node) throws(YAMLError) -> YAMLValue {
        budget -= 1
        guard budget >= 0 else {
            throw .tooLarge
        }
        switch node {
        case .scalar(let scalar):
            return YAMLScalars.value(of: scalar.string, tag: node.tag.description)
        case .sequence(let sequence):
            var values: [YAMLValue] = []
            for element in sequence {
                values.append(try value(element))
            }
            return .array(values)
        case .mapping(let mapping):
            return .object(try members(of: mapping))
        case .alias:
            // The composer resolves every alias to the node it names, so none reaches here.
            throw YAMLError(message: "It has an alias that names nothing.")
        }
    }

    /// The mapping's members in order. A plain `<<` key merges in the mapping it names, or each of a list of them, at
    /// its place: the mapping's own keys win over merged ones, and an earlier merged mapping over a later one. A key
    /// two scalars spell the same (`1` and `"1"`) keeps its first place and its last value, as JSON readers do.
    private mutating func members(of mapping: Node.Mapping) throws(YAMLError) -> [YAMLMember] {
        let ownKeys = Set(mapping.filter { !Self.isMergeKey($0.key) }.compactMap(\.key.scalar?.string))
        var members: [YAMLMember] = []
        var indices: [String: Int] = [:]
        func add(_ member: YAMLMember, replacing: Bool) {
            if let index = indices[member.key] {
                if replacing {
                    members[index] = member
                }
            } else {
                indices[member.key] = members.count
                members.append(member)
            }
        }
        for (key, value) in mapping {
            if Self.isMergeKey(key) {
                for source in try merged(value) where !ownKeys.contains(source.key) {
                    add(source, replacing: false)
                }
            } else {
                add(YAMLMember(key: try text(of: key), value: try self.value(value)), replacing: true)
            }
        }
        return members
    }

    private mutating func merged(_ node: Node) throws(YAMLError) -> [YAMLMember] {
        switch node {
        case .mapping(let mapping):
            return try members(of: mapping)
        case .sequence(let sequence):
            var result: [YAMLMember] = []
            for element in sequence {
                guard case .mapping(let mapping) = element else {
                    throw Self.badMerge(element)
                }
                let present = Set(result.map(\.key))
                result += try members(of: mapping).filter { !present.contains($0.key) }
            }
            return result
        default:
            throw Self.badMerge(node)
        }
    }

    private mutating func text(of key: Node) throws(YAMLError) -> String {
        if let scalar = key.scalar {
            return scalar.string
        }
        return try value(key).jsonText()
    }

    private static func isMergeKey(_ key: Node) -> Bool {
        key.scalar?.string == "<<" && key.tag.description == YAMLScalars.plainTag
    }

    private static func badMerge(_ node: Node) -> YAMLError {
        YAMLError(message: "A << merge key needs a mapping or a list of mappings.", line: node.mark?.line, column: node.mark?.column)
    }
}

extension YAMLError {
    /// Yams' error as one message and where, without the snippet of the text Yams' own description quotes.
    init(_ error: YamlError, in text: String) {
        switch error {
        case .scanner(let context, let problem, let mark, _),
             .parser(let context, let problem, let mark, _),
             .composer(let context, let problem, let mark, _):
            self.init(message: Self.sentence(context.map { "\($0.text), \(problem)" } ?? problem), line: mark.line, column: mark.column)
        case .reader(let problem, let offset, _, _):
            let line = offset.map { text.prefix($0).count(where: \.isNewline) + 1 }
            self.init(message: Self.sentence(problem), line: line)
        case .duplicatedKeysInMapping(let duplicates, let context):
            let listed = duplicates.map { "“\($0)”" }.joined(separator: ", ")
            self.init(message: "A mapping repeats the key \(listed).", line: context.mark.line, column: context.mark.column)
        default:
            self.init(message: String(describing: error))
        }
    }

    /// libyaml's lower-case phrase (`did not find expected key`) as a sentence.
    private static func sentence(_ phrase: String) -> String {
        "\(phrase.prefix(1).uppercased())\(phrase.dropFirst())."
    }
}
