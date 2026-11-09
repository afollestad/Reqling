import Foundation
internal import ReqlingYAML

/// An OpenAPI document with the documents its `$ref`s name, and the external values its examples point at, loaded and
/// ready to plan (`OpenAPIImporter.plan`), which then never waits on the network.
public struct OpenAPISource: Sendable {
    public let document: OpenAPIDocument
    /// Every loaded document by its URL without a fragment, the root's included.
    var documents: [URL: YAMLValue]
    /// Why a document or external value couldn't be loaded, by its URL; a reference that lands on one becomes a note.
    var failures: [URL: String] = [:]
    /// Example values given by `externalValue`, as text.
    var externalValues: [URL: String] = [:]

    /// What couldn't be loaded, one line each, for the import sheet to show before Import.
    public var problems: [String] {
        failures.keys.sorted { $0.absoluteString < $1.absoluteString }.compactMap { url in
            failures[url].map { "“\(ImportError.displayName(of: url))”: \($0)" }
        }
    }

    /// How many operations the document describes, for the import sheet to say before Import.
    public var operationCount: Int {
        OpenAPIOperations.collect(in: self).operations.count
    }
}

/// Loads every document an OpenAPI document's `$ref`s name, breadth-first, each once whatever refers to it, so cycles
/// between files cost nothing. A document imported from a file follows other files only, and one fetched from a URL
/// http(s) only, so a fetched document can never read this Mac's files. A document or value that can't be loaded is
/// kept as a failure for the plan to note where it's used.
public enum OpenAPILoader {
    public static let maximumDocuments = 64
    public static let maximumTotalBytes = 64 * 1024 * 1024
    public static let maximumExternalValues = 20
    public static let maximumExternalValueBytes = 1024 * 1024

    public static func load(_ document: OpenAPIDocument, fetcher: any ImportFetching) async -> OpenAPISource {
        let rootURL = OpenAPIReferences.documentKey(document.location)
        var source = OpenAPISource(document: document, documents: [rootURL: document.root])
        var queue = [rootURL]
        var index = 0
        var totalBytes = 0
        while index < queue.count, !Task.isCancelled {
            let url = queue[index]
            index += 1
            guard let value = source.documents[url] else {
                continue
            }
            let base = OpenAPIReferences.base(of: value, retrievedFrom: url)
            for target in OpenAPIReferences.documentTargets(in: value, base: base) where source.isUnseen(target) {
                if let refusal = refusal(of: target, root: document.location) {
                    source.failures[target] = refusal
                } else if source.documents.count >= maximumDocuments || totalBytes >= maximumTotalBytes {
                    source.failures[target] = "It wasn't loaded: the document names more than Reqling loads for one import."
                } else if let (data, value) = await fetch(target, with: fetcher, into: &source) {
                    totalBytes += data.count
                    source.documents[target] = value
                    queue.append(target)
                }
            }
        }
        await loadExternalValues(into: &source, fetcher: fetcher)
        return source
    }

    /// Why `target` isn't followed from a document imported from `root`; `nil` when it is.
    static func refusal(of target: URL, root: URL) -> String? {
        let isWeb = ["http", "https"].contains(target.scheme?.lowercased() ?? "")
        if root.isFileURL {
            return target.isFileURL ? nil : "It wasn't loaded: a document imported from a file follows only files beside it."
        }
        return isWeb ? nil : "It wasn't loaded: a document fetched from a URL never reads files on this Mac."
    }

    private static func fetch(_ target: URL, with fetcher: any ImportFetching, into source: inout OpenAPISource) async -> (Data, YAMLValue)? {
        do {
            let (data, _) = try await fetcher.data(from: target)
            return (data, try StructuredText.parse(data))
        } catch let error as ImportError {
            source.failures[target] = error.errorDescription ?? "It couldn't be loaded."
        } catch let error as StructuredTextError {
            source.failures[target] = "It isn't valid JSON or YAML. \(error.message)"
        } catch {
            source.failures[target] = error.localizedDescription
        }
        return nil
    }

    /// The examples given only by `externalValue`, fetched as text under the same rules as documents, up to a limit.
    private static func loadExternalValues(into source: inout OpenAPISource, fetcher: any ImportFetching) async {
        var targets: [URL] = []
        for (url, value) in source.documents {
            let base = OpenAPIReferences.base(of: value, retrievedFrom: url)
            targets += OpenAPIReferences.externalValues(in: value, base: base)
        }
        for target in Set(targets).sorted(by: { $0.absoluteString < $1.absoluteString }).prefix(maximumExternalValues) {
            guard !Task.isCancelled else {
                return
            }
            if let refusal = refusal(of: target, root: source.document.location) {
                source.failures[target] = refusal
                continue
            }
            do {
                let (data, _) = try await fetcher.data(from: target)
                guard data.count <= maximumExternalValueBytes, let text = String(data: data, encoding: .utf8) else {
                    source.failures[target] = "It isn't text Reqling can use as an example."
                    continue
                }
                source.externalValues[target] = text
            } catch {
                source.failures[target] = error.errorDescription ?? "It couldn't be loaded."
            }
        }
    }
}

private extension OpenAPISource {
    func isUnseen(_ url: URL) -> Bool {
        documents[url] == nil && failures[url] == nil
    }
}
