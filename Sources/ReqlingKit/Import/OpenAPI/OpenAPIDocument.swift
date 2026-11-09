import Foundation
internal import ReqlingYAML

/// An OpenAPI 3 document as read, before the documents its references name are loaded (`OpenAPILoader`). Versions 3.0,
/// 3.1, and 3.2 import; a later 3.x imports what it shares with them, with a note.
public struct OpenAPIDocument: Sendable {
    /// `info.title`, which the project takes, or the file's name without its extension.
    public let title: String
    /// The `openapi` field, such as `3.1.0`.
    public let version: String
    /// Where it was read from: what its relative references and servers resolve against.
    public let location: URL
    let root: YAMLValue
    let minorVersion: Int

    init(_ root: YAMLValue, location: URL, name: String) throws(ImportError) {
        guard let version = root["openapi"].map(\.fieldText) else {
            throw .swagger2(name)
        }
        let parts = version.split(separator: ".")
        guard parts.first == "3", parts.count >= 2, let minor = Int(parts[1]) else {
            throw .unsupportedOpenAPI(name, version: version)
        }
        let title = root["info"]?["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? (name as NSString).deletingPathExtension : title
        self.version = version
        self.location = location
        self.root = root
        minorVersion = minor
    }

    /// Schemas whose `$ref` sits beside other keywords combine them (`allOf`), as JSON Schema 2020-12 reads them;
    /// OpenAPI 3.0 ignores a reference's siblings.
    var refSiblingsCombine: Bool {
        minorVersion >= 1
    }
}
