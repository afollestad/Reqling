import Foundation
import ReqlingKit
import UniformTypeIdentifiers

/// Postman environment and globals exports brought into an existing project's environments. They merge into the
/// sheet's draft like any edit (`PostmanEnvironmentMerge`), so Done saves them, secrets to the Keychain, and Cancel
/// leaves everything as it was.
extension EnvironmentEditorModel {
    func importPostmanEnvironments() async {
        let urls = app.system.chooseFiles(prompt: "Import", message: "Choose Postman environment or globals exports.", allowedTypes: [.json])
        guard !urls.isEmpty else {
            return
        }
        var files: [PostmanFile] = []
        var problems: [String] = []
        let results = await Task.detached { PostmanFile.read(urls) }.value
        for (url, result) in results {
            switch result {
            case .success(.collection):
                problems.append(PostmanImportError.notAnEnvironment(url.lastPathComponent).localizedDescription
                    + " Import it with File ▸ Import Postman Collection….")
            case .success(let file):
                files.append(file)
            case .failure(let error):
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty {
            app.alert = AppAlert(title: "Some Files Weren't Imported", message: problems.joined(separator: "\n"))
        }
        guard !files.isEmpty else {
            return
        }
        var targets = PostmanEnvironmentMerge.Targets(global: globalEnvironment, defaultEnvironment: defaultEnvironment, environments: environments)
        let (changes, touched) = PostmanEnvironmentMerge.merge(files, into: &targets)
        globalEnvironment = targets.global
        defaultEnvironment = targets.defaultEnvironment
        environments = targets.environments
        if let first = touched.first {
            selectedID = first
        }
        let lines = changes.compactMap(PostmanImportPresentation.line)
        postmanImportNote = lines.isEmpty ? "The Postman files changed nothing." : lines.joined(separator: " ") + " Done saves them."
    }
}
