import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// The import sheet's state: the source as a URL or a file's path, what was found there once it's loaded, the
/// environment and globals files a Postman collection can bring, the new project's name and place, then what the import
/// made. A source is read, and an OpenAPI document's references loaded, at Load, so a wrong one says why before Import.
@MainActor
@Observable
final class ImportModel {
    /// A Postman environment or globals file as chosen, read.
    struct ChosenFile: Identifiable {
        let id = UUID()
        let url: URL
        let file: PostmanFile

        var name: String {
            url.lastPathComponent
        }

        var isGlobals: Bool {
            if case .globals = file {
                return true
            }
            return false
        }
    }

    /// What a loaded source holds.
    enum Source: Sendable {
        /// A collection, with where it was read from, which its body files are looked for beside.
        case postman(PostmanCollection, URL)
        case openAPI(OpenAPISource)
    }

    enum Phase {
        case choosing
        case importing
        case finished(ProjectImportPresentation)
    }

    /// A URL or a file's path, as typed or chosen. Changing it drops what was loaded from the last one.
    var sourceText = "" {
        didSet {
            if sourceText != loadedText {
                clearSource()
            }
        }
    }
    private(set) var isLoading = false
    private(set) var source: Source?
    /// What the source holds, in a line, once loaded: `OpenAPI 3.1.0 · “Petstore” · 19 operations`.
    private(set) var found: String?
    /// The documents and examples an OpenAPI document refers to that couldn't be loaded; the rest still imports.
    private(set) var loadProblems: [String] = []
    private(set) var variableFiles: [ChosenFile] = []
    var name = ""
    var location: URL?
    /// Why the source or a file chosen wasn't taken.
    private(set) var problem: String?
    private(set) var phase = Phase.choosing

    @ObservationIgnored unowned let app: AppModel
    /// The name taken from the source, so loading another renames only a name the person didn't type.
    @ObservationIgnored private var suggestedName = ""
    /// The text `source` was loaded from.
    @ObservationIgnored private var loadedText: String?

    init(app: AppModel) {
        self.app = app
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isPostman: Bool {
        if case .postman? = source {
            return true
        }
        return false
    }

    var canLoad: Bool {
        guard case .choosing = phase else {
            return false
        }
        return !isLoading && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canImport: Bool {
        guard case .choosing = phase else {
            return false
        }
        return !isLoading && source != nil && !trimmedName.isEmpty
    }

    func chooseFile() async {
        let message = "Choose a Postman collection, or an OpenAPI 3 document in JSON or YAML."
        guard let url = app.system.chooseFile(prompt: "Choose", message: message, allowedTypes: [.json, .yaml]) else {
            return
        }
        sourceText = (url.path as NSString).abbreviatingWithTildeInPath
        await load()
    }

    /// Reads the source off the main actor, and for an OpenAPI document every document its references name.
    func load() async {
        guard canLoad else {
            return
        }
        guard let url = Self.url(from: sourceText) else {
            problem = "Enter a URL or a file's path."
            return
        }
        let text = sourceText
        isLoading = true
        clearSource()
        let fetcher = app.importFetcher
        let result = await Task.detached { await Self.read(url, fetcher: fetcher) }.value
        isLoading = false
        // Typed over meanwhile: what loaded no longer matches the field.
        guard sourceText == text else {
            return
        }
        switch result {
        case .success(let source):
            loadedText = text
            show(source)
        case .failure(let error):
            problem = error.localizedDescription
        }
    }

    func addVariableFiles() async {
        let urls = app.system.chooseFiles(prompt: "Add", message: "Choose Postman environment or globals exports.", allowedTypes: [.json])
        problem = nil
        let results = await Task.detached { PostmanFile.read(urls) }.value
        for (url, result) in results {
            switch result {
            case .success(.collection):
                problem = PostmanImportError.notAnEnvironment(url.lastPathComponent).localizedDescription + " Import it as its own project."
            case .success(let file):
                variableFiles.append(ChosenFile(url: url, file: file))
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    func removeVariableFile(_ id: UUID) {
        variableFiles.removeAll { $0.id == id }
    }

    /// Plans the import off the main actor, then writes the project and selects it, so Done only closes the sheet.
    func startImport() async {
        guard canImport, let source else {
            return
        }
        phase = .importing
        problem = nil
        // What the form says now, before the wait.
        let (name, location, files) = (trimmedName, self.location, variableFiles.map(\.file))
        let plan = await Task.detached { Self.plan(source, files: files) }.value
        let title = isPostman ? "Couldn't Import the Collection" : "Couldn't Import the Document"
        guard let result = app.perform(title, { try app.lifecycle.importProject(plan, named: name, in: location) }) else {
            phase = .choosing
            return
        }
        app.selection = .project(result.project)
        phase = .finished(ProjectImportPresentation(name: name, plan: plan, result: result))
    }

    /// A URL as typed, `http(s)` or `file`, or else a file's path, `~` expanded.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        let scheme = text.prefix { $0 != ":" }.lowercased()
        if ["http", "https", "file"].contains(scheme), text.dropFirst(scheme.count).hasPrefix("://") {
            return URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }

    private func show(_ source: Source) {
        self.source = source
        let title: String
        switch source {
        case .postman(let collection, _):
            title = collection.name
            found = "Postman collection · “\(collection.name)” · \(Self.count(collection.requestCount, "request"))"
        case .openAPI(let openAPI):
            title = openAPI.document.title
            found = "OpenAPI \(openAPI.document.version) · “\(title)” · \(Self.count(openAPI.operationCount, "operation"))"
            loadProblems = openAPI.problems
            variableFiles = []
        }
        if name == suggestedName || trimmedName.isEmpty {
            name = title
        }
        suggestedName = title
    }

    private func clearSource() {
        source = nil
        found = nil
        loadProblems = []
        problem = nil
        loadedText = nil
    }

    private nonisolated static func read(_ url: URL, fetcher: any ImportFetching) async -> Result<Source, ImportError> {
        do {
            let (data, location) = try await fetcher.data(from: url)
            switch try ImportDocument.read(data, location: location) {
            case .postman(let collection):
                return .success(.postman(collection, location))
            case .openAPI(let document):
                return .success(.openAPI(await OpenAPILoader.load(document, fetcher: fetcher)))
            }
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func plan(_ source: Source, files: [PostmanFile]) -> ProjectImport {
        switch source {
        case .postman(let collection, let location):
            PostmanImporter.plan(collection, files: files, collectionDirectory: location.isFileURL ? location.deletingLastPathComponent() : nil)
        case .openAPI(let openAPI):
            OpenAPIImporter.plan(openAPI)
        }
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
