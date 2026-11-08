import Foundation
import ReqlingTemplating

/// Postman's body modes as Reqling's: `raw` with the type Postman sent it as, `urlencoded`, `formdata` with its files,
/// `file` as a binary body, and `graphql`.
extension PostmanPlanner {
    mutating func body(
        _ body: PostmanJSON?,
        into spec: inout HTTPRequestSpec,
        request: RequestNodeID,
        owner: PostmanImportNote.Owner,
        sendsDespiteMethod: Bool
    ) {
        guard let body, let mode = body["mode"]?.string else {
            return
        }
        var result = HTTPBody()
        switch mode {
        case "raw":
            // Postman sends a raw body with a typed `Content-Type` header if there is one, or else the language's.
            let contentType = Self.takeContentType(from: &spec.headers) ?? Self.contentType(forLanguage: body["options"]?["raw"]?["language"]?.string)
            result.raw = RawBody(text: body["raw"]?.text ?? "", contentType: contentType)
            result.mode = .raw
        case "urlencoded":
            result.urlEncoded = Self.rows(body["urlencoded"])
            result.mode = .urlEncoded
        case "formdata":
            result.formData = formFields(body["formdata"], request: request, owner: owner)
            result.mode = .formData
        case "file":
            result.binary.contentType = Self.takeContentType(from: &spec.headers)
            if let url = file(body["file"]?["src"]?.string, part: nil, owner: owner) {
                files.append(PostmanFileSlot(request: request, target: .binary, url: url))
            }
            result.mode = .binary
        case "graphql":
            let graphQL = body["graphql"]
            result.graphQL = GraphQLBody(query: graphQL?["query"]?.text ?? "", variables: graphQL?["variables"]?.text ?? "")
            result.mode = .graphQL
        default:
            note(owner, .body, "Its body's “\(mode)” mode isn't one Reqling has, so it has no body.")
        }
        if body["disabled"]?.bool == true {
            // Postman keeps a turned-off body's content, and so does Reqling: only the mode decides what's sent.
            result.mode = .none
        }
        if sendsDespiteMethod, !spec.method.bodyPolicy.allowsBody, result.mode != .none {
            note(owner, .body, "Postman sent its body with \(spec.method.rawValue), which Reqling never does; it's kept for another method.")
        }
        spec.body = result
    }

    /// Form parts: text as typed, and a file part for each file a `src` names, its file found on this Mac or left to
    /// choose.
    private mutating func formFields(_ list: PostmanJSON?, request: RequestNodeID, owner: PostmanImportNote.Owner) -> [MultipartField] {
        (list?.array ?? []).flatMap { entry -> [MultipartField] in
            let key = entry["key"]?.text ?? ""
            let isEnabled = !(entry["disabled"]?.bool ?? false)
            let contentType = entry["contentType"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            guard entry["type"]?.string == "file" else {
                return [MultipartField(key: key, kind: .text, value: entry["value"]?.text ?? "", contentType: contentType, isEnabled: isEnabled)]
            }
            let sources = entry["src"]?.array?.compactMap(\.string) ?? [entry["src"]?.string].compactMap(\.self)
            return (sources.isEmpty ? [nil] : sources.map(Optional.some)).map { source in
                let field = MultipartField(key: key, kind: .file, contentType: contentType, isEnabled: isEnabled)
                if let url = file(source, part: key, owner: owner) {
                    files.append(PostmanFileSlot(request: request, target: .formField(field.id), url: url))
                }
                return field
            }
        }
    }

    /// The file a `src` names on this Mac: as written (`~` expanded), then beside the collection, then in Postman's
    /// own files folder. `nil`, with a note asking to choose it, when it isn't found.
    private mutating func file(_ source: String?, part: String?, owner: PostmanImportNote.Owner) -> URL? {
        let source = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what = part.map { "the file for “\($0)”" } ?? "its body's file"
        guard !source.isEmpty else {
            note(owner, .file, "Choose \(what), which Postman didn't name.")
            return nil
        }
        let expanded = (source as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = expanded.hasPrefix("/")
            ? [URL(fileURLWithPath: expanded)]
            : [collectionDirectory?.appendingPathComponent(source), home.appendingPathComponent("Postman/files").appendingPathComponent(source)]
                .compactMap(\.self)
        if let found = candidates.first(where: Self.isFile) {
            return found.standardizedFileURL
        }
        note(owner, .file, "Choose \(what), which Postman had at “\(source)”; it isn't on this Mac.")
        return nil
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// An enabled `Content-Type` header, taken out of the headers to be the body's own type, as cURL import does. One
    /// built from variables stays a header, which overrides the body's type when sent.
    private static func takeContentType(from headers: inout [KeyValuePair]) -> String? {
        guard let index = headers.firstIndex(where: {
            $0.isEnabled && $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame && TemplateParser.tokens(in: $0.value).isEmpty
        }) else {
            return nil
        }
        return headers.remove(at: index).value
    }

    /// The `Content-Type` Postman sends a raw body with for the language it's typed as; text when none is given.
    private static func contentType(forLanguage language: String?) -> String {
        switch language?.lowercased() {
        case "json": "application/json"
        case "xml": "application/xml"
        case "html": "text/html"
        case "javascript": "application/javascript"
        default: "text/plain"
        }
    }
}
