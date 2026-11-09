import Foundation
internal import ReqlingYAML

/// What an import starts from, recognized by its content rather than its name or type: a Postman collection, or an
/// OpenAPI 3 document in JSON or YAML.
public enum ImportDocument: Sendable {
    case postman(PostmanCollection)
    case openAPI(OpenAPIDocument)

    /// `location` is where the bytes came from, a file or the URL they were fetched from after redirects: an OpenAPI
    /// document's relative references and servers resolve against it.
    public static func read(_ data: Data, location: URL) throws(ImportError) -> ImportDocument {
        let name = ImportError.displayName(of: location)
        let root: YAMLValue
        do {
            root = try StructuredText.parse(data)
        } catch {
            throw .syntax(name, error.message)
        }
        if root["openapi"] != nil || root["swagger"] != nil {
            return .openAPI(try OpenAPIDocument(root, location: location, name: name))
        }
        let file: PostmanFile
        do {
            file = try PostmanFile.read(data, named: name)
        } catch {
            switch error {
            case .notJSON, .notPostman: throw .notImportable(name)
            default: throw .postman(error)
            }
        }
        guard case .collection(let collection) = file else {
            throw .postman(.notACollection(name))
        }
        return .postman(collection)
    }
}

public enum ImportError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notImportable(String)
    case syntax(String, String)
    case swagger2(String)
    case unsupportedOpenAPI(String, version: String)
    case postman(PostmanImportError)
    case fetch(String, String)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "“\(name)” couldn't be read."
        case .notImportable(let name):
            "“\(name)” isn't a Postman collection or an OpenAPI 3 document."
        case .syntax(let name, let detail):
            "“\(name)” isn't valid JSON or YAML. \(detail)"
        case .swagger2(let name):
            "“\(name)” is a Swagger 2.0 document. Convert it to OpenAPI 3, as Swagger Editor's Convert to OpenAPI 3 does, then import that."
        case .unsupportedOpenAPI(let name, let version):
            "“\(name)” is OpenAPI \(version), and Reqling imports OpenAPI 3."
        case .postman(let error):
            error.errorDescription
        case .fetch(let name, let detail):
            "“\(name)” couldn't be fetched. \(detail)"
        case .tooLarge(let name):
            "“\(name)” is larger than \(ByteCountFormatter.string(fromByteCount: Int64(LiveImportFetcher.maximumBytes), countStyle: .file))."
        }
    }

    /// Why, without naming the document, for a line that names it already, as a reference's note does.
    var reason: String {
        switch self {
        case .unreadable: "It couldn't be read."
        case .notImportable: "It isn't a Postman collection or an OpenAPI 3 document."
        case .syntax(_, let detail): "It isn't valid JSON or YAML. \(detail)"
        case .swagger2: "It's a Swagger 2.0 document."
        case .unsupportedOpenAPI(_, let version): "It's OpenAPI \(version)."
        case .postman(let error): error.errorDescription ?? "It isn't a Postman collection."
        case .fetch(_, let detail): detail
        case .tooLarge: "It's larger than \(ByteCountFormatter.string(fromByteCount: Int64(LiveImportFetcher.maximumBytes), countStyle: .file))."
        }
    }

    /// A file's name, or a URL as it reads.
    static func displayName(of url: URL) -> String {
        url.isFileURL ? url.lastPathComponent : url.absoluteString
    }
}
