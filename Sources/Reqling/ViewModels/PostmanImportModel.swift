import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// The import sheet's state: the collection and the environment and globals files chosen, the new project's name and
/// place, then what the import made. Files are read as they're chosen, so a wrong one says why before Import.
@MainActor
@Observable
final class PostmanImportModel {
    /// A file as chosen, read.
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

    enum Phase {
        case choosing
        case importing
        case finished(PostmanImportPresentation)
    }

    private(set) var collection: ChosenFile?
    private(set) var variableFiles: [ChosenFile] = []
    var name = ""
    var location: URL?
    /// Why the last file chosen wasn't taken, or the import failed.
    private(set) var problem: String?
    private(set) var phase = Phase.choosing

    @ObservationIgnored unowned let app: AppModel
    /// The name taken from the collection, so choosing another collection renames only a name the person didn't type.
    @ObservationIgnored private var suggestedName = ""

    init(app: AppModel) {
        self.app = app
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canImport: Bool {
        guard case .choosing = phase else {
            return false
        }
        return collection != nil && !trimmedName.isEmpty
    }

    func chooseCollection() async {
        guard let url = app.system.chooseFile(prompt: "Choose", message: "Choose a Postman Collection v2.1 or v2.0 export.",
                                              allowedTypes: [.json]) else {
            return
        }
        guard let chosen = await read([url]).first else {
            return
        }
        guard case .collection(let collection) = chosen.file else {
            problem = PostmanImportError.notACollection(chosen.name).localizedDescription + " Add it under Environments."
            return
        }
        self.collection = chosen
        if name == suggestedName || trimmedName.isEmpty {
            name = collection.name
        }
        suggestedName = collection.name
    }

    func addVariableFiles() async {
        let urls = app.system.chooseFiles(prompt: "Add", message: "Choose Postman environment or globals exports.", allowedTypes: [.json])
        for chosen in await read(urls) {
            if case .collection = chosen.file {
                problem = PostmanImportError.notAnEnvironment(chosen.name).localizedDescription + " Choose it as the collection."
            } else {
                variableFiles.append(chosen)
            }
        }
    }

    func removeVariableFile(_ id: UUID) {
        variableFiles.removeAll { $0.id == id }
    }

    /// Maps the collection off the main actor, then writes the project and selects it, so Done only closes the sheet.
    func startImport() async {
        guard canImport, let collection, case .collection(let postman) = collection.file else {
            return
        }
        phase = .importing
        problem = nil
        // What the form says now, before the wait.
        let (name, location, files) = (trimmedName, self.location, variableFiles.map(\.file))
        let directory = collection.url.deletingLastPathComponent()
        let plan = await Task.detached { PostmanImporter.plan(postman, files: files, collectionDirectory: directory) }.value
        guard let result = app.perform("Couldn't Import the Collection", { try app.lifecycle.importPostman(plan, named: name, in: location) }) else {
            phase = .choosing
            return
        }
        app.selection = .project(result.project)
        phase = .finished(PostmanImportPresentation(name: name, plan: plan, result: result))
    }

    /// Each file read off the main actor; one that can't be read sets `problem` and is left out.
    private func read(_ urls: [URL]) async -> [ChosenFile] {
        problem = nil
        let results = await Task.detached { PostmanFile.read(urls) }.value
        return results.compactMap { url, result in
            switch result {
            case .success(let file):
                return ChosenFile(url: url, file: file)
            case .failure(let error):
                problem = error.localizedDescription
                return nil
            }
        }
    }
}
