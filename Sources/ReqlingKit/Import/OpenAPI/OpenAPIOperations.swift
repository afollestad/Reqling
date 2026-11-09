import Foundation
internal import ReqlingYAML

/// One operation: a method on a path, with the path item it's in, whose parameters and servers it shares.
struct OpenAPIOperation {
    let path: String
    let method: HTTPMethod
    let node: OpenAPINode
    let pathItem: OpenAPINode
}

/// The operations under `paths`, in document order: each path item's methods in the order it lists them, `query` (3.2)
/// as `QUERY`, then its 3.2 `additionalOperations` by the names they're given.
enum OpenAPIOperations {
    static let methods: [String: HTTPMethod] = [
        "get": .get, "put": .put, "post": .post, "delete": .delete, "options": .options, "head": .head, "patch": .patch,
        "trace": HTTPMethod(rawValue: "TRACE"), "query": HTTPMethod(rawValue: "QUERY")
    ]

    struct Collected {
        var operations: [OpenAPIOperation] = []
        /// What couldn't be read, by path: a path item reference that couldn't be followed, or a method that isn't one.
        var problems: [(path: String, message: String)] = []
    }

    static func collect(in source: OpenAPISource) -> Collected {
        let resolver = OpenAPIResolver(source: source)
        let root = OpenAPINode(value: source.document.root, document: OpenAPIReferences.documentKey(source.document.location))
        var collected = Collected()
        for (path, entry) in root["paths"]?.members ?? [] {
            let pathItem: OpenAPINode
            switch resolver.resolve(entry) {
            case .success(let resolved):
                pathItem = resolved
            case .failure(let failure):
                collected.problems.append((path, failure.message))
                continue
            }
            for (key, operation) in pathItem.members {
                if let method = methods[key] {
                    collected.operations.append(OpenAPIOperation(path: path, method: method, node: operation, pathItem: pathItem))
                }
            }
            for (name, operation) in pathItem["additionalOperations"]?.members ?? [] {
                let method = HTTPMethod(rawValue: name)
                guard method.isValid else {
                    collected.problems.append((path, "Its “\(name)” operation isn't imported: that isn't an HTTP method."))
                    continue
                }
                collected.operations.append(OpenAPIOperation(path: path, method: method, node: operation, pathItem: pathItem))
            }
        }
        return collected
    }
}
