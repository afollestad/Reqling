import Foundation
internal import ReqlingYAML

/// YAML bodies re-emitted and turned into JSON, for a YAML response's Pretty and Tree views. Unlike `JSONFormatter`,
/// it parses, so comments, anchors, and quoting style aren't kept: Pretty shows the data, laid out evenly.
public enum YAMLFormatter {
    /// The body's documents as two-space block YAML, several separated by `---`; `nil` when it isn't YAML.
    public static func pretty(_ body: Data) -> String? {
        (try? YAML.parseAll(body)).map(YAML.text)
    }

    /// A JSON value as YAML, for copying a YAML tree's object or array as the body wrote it; `nil` when it isn't JSON.
    public static func yaml(fromJSON text: String) -> String? {
        (try? YAML.parse(text)).map { $0.yamlText() }
    }

    /// The body as one JSON value for `JSONStructureIndex`: its document, or a list of them for a stream of several, or
    /// `null` for none. Throws where the body stops being YAML, with the line.
    static func treeJSON(_ body: Data) throws(YAMLError) -> Data {
        let documents = try YAML.parseAll(body)
        let root: YAMLValue = switch documents.count {
        case 0: .null
        case 1: documents[0]
        default: .array(documents)
        }
        return Data(root.jsonText().utf8)
    }
}
