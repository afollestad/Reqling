import Foundation

/// A file Postman exports: a collection, an environment, or its globals, recognized by its content rather than its name.
public enum PostmanFile: Sendable {
    case collection(PostmanCollection)
    case environment(PostmanVariableFile)
    case globals(PostmanVariableFile)

    public static func read(_ url: URL) throws(PostmanImportError) -> PostmanFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(url.lastPathComponent)
        }
        return try read(data, named: url.lastPathComponent)
    }

    /// Each file read, in order, or why it couldn't be; for a batch the person chose, which off the main actor stays
    /// responsive while a large export decodes.
    public static func read(_ urls: [URL]) -> [(url: URL, result: Result<PostmanFile, PostmanImportError>)] {
        urls.map { url in (url, Result { () throws(PostmanImportError) in try read(url) }) }
    }

    /// `name` is the file's, for messages.
    public static func read(_ data: Data, named name: String) throws(PostmanImportError) -> PostmanFile {
        guard let root = try? JSONDecoder().decode(PostmanJSON.self, from: data), root.object != nil else {
            throw .notJSON(name)
        }
        if root["info"] != nil, root["item"]?.array != nil {
            return .collection(PostmanCollection(root: root))
        }
        if root["requests"] != nil, root["order"] != nil || root["folders"] != nil {
            throw .collectionV1(name)
        }
        if let values = root["values"]?.array {
            let file = PostmanVariableFile(name: root["name"]?.string ?? "", values: values)
            return root["_postman_variable_scope"]?.string == "globals" ? .globals(file) : .environment(file)
        }
        throw .notPostman(name)
    }
}

/// A Postman Collection, v2.0 or v2.1, as exported.
public struct PostmanCollection: Sendable {
    let root: PostmanJSON

    /// The collection's name, which a new project takes.
    public var name: String {
        root["info"]?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// How many requests it holds, its folders' included, for the import sheet to say before Import.
    public var requestCount: Int {
        func count(_ items: PostmanJSON?) -> Int {
            (items?.array ?? []).reduce(0) { total, item in total + (item["item"]?.array != nil ? count(item["item"]) : 1) }
        }
        return count(root["item"])
    }
}

/// A Postman environment, or Postman's globals, as exported.
public struct PostmanVariableFile: Sendable {
    public let name: String
    /// Postman's `values`: its variables, in order. A secret one is typed `secret`; a disabled one is `enabled: false`.
    public let variables: [Variable]

    init(name: String, values: [PostmanJSON]) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        variables = values.compactMap { value in
            guard let key = value["key"]?.string, !key.isEmpty else {
                return nil
            }
            return Variable(
                key: key,
                value: value["value"]?.text ?? "",
                isEnabled: value["enabled"]?.bool ?? true,
                isSecret: value["type"]?.string == "secret"
            )
        }
    }
}

public enum PostmanImportError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notJSON(String)
    case notPostman(String)
    case collectionV1(String)
    /// A collection chosen where environments go, or an environment where the collection does.
    case notACollection(String)
    case notAnEnvironment(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "“\(name)” couldn't be read."
        case .notJSON(let name): "“\(name)” isn't JSON."
        case .notPostman(let name): "“\(name)” isn't a Postman collection, environment, or globals export."
        case .collectionV1(let name): "“\(name)” is a Postman Collection v1. Export it from Postman again as Collection v2.1."
        case .notACollection(let name): "“\(name)” is a Postman environment or globals export, not a collection."
        case .notAnEnvironment(let name): "“\(name)” is a Postman collection, not an environment or globals export."
        }
    }
}
