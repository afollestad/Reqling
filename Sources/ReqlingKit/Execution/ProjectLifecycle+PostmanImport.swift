import Foundation

/// Writing a Postman import (`PostmanImporter.plan`) as a new project, for the window's import sheet.
extension ProjectLifecycle {
    /// What `importPostman` made: the project, and what it did to the Global environment every project shares.
    public struct PostmanProjectImport: Sendable {
        public let project: ProjectID
        public let globalChange: PostmanEnvironmentChange?
        /// Why the globals couldn't be merged, when they couldn't; the project is written either way.
        public let globalProblem: String?
    }

    /// Creates the project and writes the whole import in one save, its secrets to the Keychain, then merges the
    /// globals into Global. A failed save moves the half-made project to the Trash; should that fail too, it stays in
    /// the library, empty, for the person to delete.
    ///
    /// Unlike `createProject`, the project trusts its scripts only when the import brought none: someone else wrote a
    /// collection's scripts, and they can read every variable, so the first Send asks first, as for a project added
    /// from a folder.
    @discardableResult
    public func importPostman(_ plan: PostmanImport, named name: String, in directory: URL? = nil) throws -> PostmanProjectImport {
        let id = try library.createProject(named: name, in: directory)
        do {
            guard let root = library.project(id)?.url else {
                throw ProjectStorageError.projectNotFound
            }
            var references: [PostmanFileSlot: ProjectPathReference] = [:]
            for slot in plan.files {
                references[slot] = ProjectPathResolver.sharesLocation(slot.url, with: root)
                    ? .relative(ProjectPathResolver.relativePath(from: root, to: slot.url))
                    : workspace.addLocalPath(slot.url.path, in: id)
            }
            try library.mutate(id) { document in
                document.auth = plan.auth
                document.scripts = plan.scripts
                document.items = plan.items.map { Self.pointing($0, at: references) }
                // Default keeps the ID `createProject` gave it.
                document.defaultEnvironment.variables = plan.defaultVariables
                document.environments = plan.environments
            }
        } catch {
            try? deleteProject(id)
            throw error
        }
        workspace.updateProject(id) { $0.scriptTrust = plan.hasScripts ? .unknown : .trusted }
        guard !plan.globals.isEmpty else {
            return PostmanProjectImport(project: id, globalChange: nil, globalProblem: nil)
        }
        do {
            // Merged inside the mutation, which rereads Global's secrets first, so blanks a failed read left never
            // overwrite stored values.
            let change = try library.mutateGlobalEnvironment { global in
                let (added, updated) = PostmanEnvironmentMerge.merge(plan.globals, into: &global)
                return PostmanEnvironmentChange(environment: RequestEnvironment.globalName, isNew: false, added: added, updated: updated)
            }
            return PostmanProjectImport(project: id, globalChange: change, globalProblem: nil)
        } catch {
            return PostmanProjectImport(project: id, globalChange: nil, globalProblem: error.localizedDescription)
        }
    }

    /// `node` with each body file the import found pointed at.
    private static func pointing(_ node: RequestNode, at references: [PostmanFileSlot: ProjectPathReference]) -> RequestNode {
        switch node {
        case .folder(var folder):
            folder.children = folder.children.map { pointing($0, at: references) }
            return .folder(folder)
        case .request(var request):
            guard case .http(var spec) = request.kind else {
                return node
            }
            for (slot, reference) in references where slot.request == request.id {
                switch slot.target {
                case .binary:
                    spec.body.binary.file = reference
                case .formField(let field):
                    if let index = spec.body.formData.firstIndex(where: { $0.id == field }) {
                        spec.body.formData[index].file = reference
                    }
                }
            }
            request.kind = .http(spec)
            return .request(request)
        }
    }
}
