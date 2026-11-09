import Foundation

/// The files the person chose on this Mac, per project: the absolute paths behind `ProjectPathReference.local`, the
/// shared paths outside a project's folder and repository they chose to allow, the slots each was chosen for, and the
/// files read as client identities. Project files hold none of it, so whoever else edits a project can name these
/// choices but never make one, or move one into another field (`ProjectPathResolver`).
extension WorkspaceStateStore {
    public func localPath(_ id: LocalPathID, in project: ProjectID) -> String? {
        projectState(project).localPaths[id.description]
    }

    /// The absolute paths behind `project`'s local references, for its `ProjectPathResolver`.
    public func localPaths(in project: ProjectID) -> [LocalPathID: String] {
        Dictionary(uniqueKeysWithValues: projectState(project).localPaths.compactMap { key, value in
            LocalPathID(string: key).map { ($0, value) }
        })
    }

    /// Each choice in `project`, a local path or a chosen outside path, with the slots it was chosen for, for its
    /// `ProjectPathResolver`. One recorded before slots were has none until its project loads.
    public func choices(in project: ProjectID) -> [ProjectPathReference: Set<ProjectPathSlot>] {
        let state = projectState(project)
        var choices: [ProjectPathReference: Set<ProjectPathSlot>] = [:]
        for (key, slots) in state.localPathSlots where state.localPaths[key] != nil {
            if let id = LocalPathID(string: key) {
                choices[.local(id)] = slots
            }
        }
        for (path, slots) in state.chosenOutsideSlots where state.chosenOutsidePaths.contains(path) {
            choices[.relative(path)] = slots
        }
        return choices
    }

    /// Records an absolute path for a new this-Mac-only reference in `project`, chosen for `slot`, and returns it.
    public func addLocalPath(_ path: String, for slot: ProjectPathSlot, in project: ProjectID) -> ProjectPathReference {
        let id = LocalPathID()
        updateProject(project) { state in
            state.localPaths[id.description] = path
            state.localPathSlots[id.description] = [slot]
        }
        return .local(id)
    }

    /// Gives an existing this-Mac-only reference with no path here a path, chosen for `slot`, as when one chosen on
    /// another Mac is chosen again here: keeping its ID keeps the other Mac's own path for it working once the change
    /// syncs.
    public func setLocalPath(_ path: String, for id: LocalPathID, at slot: ProjectPathSlot, in project: ProjectID) {
        updateProject(project) { state in
            state.localPaths[id.description] = path
            state.localPathSlots[id.description] = [slot]
        }
    }

    /// Records that the person chose to share `path`, outside `project`'s folder and repository, for `slot` on this Mac.
    public func addChosenOutsidePath(_ path: String, for slot: ProjectPathSlot, in project: ProjectID) {
        updateProject(project) { state in
            state.chosenOutsidePaths.insert(path)
            state.chosenOutsideSlots[path, default: []].insert(slot)
        }
    }

    /// Extends a choice made in `project` to `slot`, as for a copy of the request holding it. Does nothing for a
    /// reference that isn't one: a local path recorded on another Mac, or a shared path nobody chose here.
    public func choose(_ reference: ProjectPathReference, for slot: ProjectPathSlot, in project: ProjectID) {
        let state = projectState(project)
        switch reference {
        case .local(let id):
            let key = id.description
            guard state.localPaths[key] != nil, state.localPathSlots[key]?.contains(slot) != true else {
                return
            }
            updateProject(project) { $0.localPathSlots[key, default: []].insert(slot) }
        case .relative(let path):
            guard state.chosenOutsidePaths.contains(path), state.chosenOutsideSlots[path]?.contains(slot) != true else {
                return
            }
            updateProject(project) { $0.chosenOutsideSlots[path, default: []].insert(slot) }
        }
    }

    /// Keeps exactly the choices `project` holds (`ProjectDocument.placedReferences`): claims local paths recorded
    /// before paths were kept per project, deletes the rest, whose references are gone, keeps each choice only for the
    /// slots that still hold it, and gives each choice recorded before slots were the slots its reference holds now.
    ///
    /// Call it when a project loads (launch, or adding its folder), never after an edit: undo can restore a reference
    /// removed earlier in the session, and its path and slot must still be here when it does. From the next load on, a
    /// slot no longer holding its choice, as for a request since deleted or a file since replaced, can't be named again
    /// by someone else's change, which could otherwise recreate the request under its ID or put the old file back.
    public func reconcileChoices(in project: ProjectID, holding placed: [PlacedPathReference]) {
        let held = Self.slots(of: placed)
        update { state in
            var projectState = state.projects[project.description] ?? ProjectWorkspaceState()
            var localKeys = Set<String>()
            var relativePaths = Set<String>()
            for reference in held.keys {
                switch reference {
                case .local(let id):
                    localKeys.insert(id.description)
                    if projectState.localPaths[id.description] == nil, let path = state.unclaimedLocalPaths.removeValue(forKey: id.description) {
                        projectState.localPaths[id.description] = path
                    }
                case .relative(let path):
                    relativePaths.insert(path)
                }
            }
            projectState.localPaths = projectState.localPaths.filter { localKeys.contains($0.key) }
            projectState.localPathSlots = projectState.localPathSlots.reduce(into: [:]) { kept, entry in
                if let id = LocalPathID(string: entry.key), let holding = held[.local(id)] {
                    kept[entry.key] = entry.value.intersection(holding)
                }
            }
            projectState.chosenOutsidePaths.formIntersection(relativePaths)
            projectState.chosenOutsideSlots = projectState.chosenOutsideSlots.reduce(into: [:]) { kept, entry in
                if let holding = held[.relative(entry.key)] {
                    kept[entry.key] = entry.value.intersection(holding)
                }
            }
            Self.slotUnslotted(&projectState, holding: held)
            if projectState != (state.projects[project.description] ?? ProjectWorkspaceState()) {
                state.projects[project.description] = projectState
            }
        }
    }

    /// Gives each choice in `project` recorded before slots were the slots its reference holds in `placed`, this Mac's
    /// copy, before another Mac's change lands on it; otherwise the next load would take wherever that change put the
    /// reference as where it was chosen.
    public func slotUnslottedChoices(in project: ProjectID, holding placed: [PlacedPathReference]) {
        let held = Self.slots(of: placed)
        update { state in
            if var projectState = state.projects[project.description] {
                Self.slotUnslotted(&projectState, holding: held)
                state.projects[project.description] = projectState
            }
        }
    }

    /// Forgets the choices in `project` recorded before slots were, for a project another Mac's change is about to
    /// write with no copy here to say where they stood.
    public func forgetUnslottedChoices(in project: ProjectID) {
        update { state in
            guard var projectState = state.projects[project.description] else {
                return
            }
            projectState.localPaths = projectState.localPaths.filter { projectState.localPathSlots[$0.key] != nil }
            projectState.chosenOutsidePaths = projectState.chosenOutsidePaths.filter { projectState.chosenOutsideSlots[$0] != nil }
            state.projects[project.description] = projectState
        }
    }

    /// The resolved paths of `project`'s files ever used for a client certificate or key
    /// (`ProjectWorkspaceState.identityFiles`).
    public func identityFiles(in project: ProjectID) -> Set<String> {
        projectState(project).identityFiles
    }

    /// Marks `paths`, resolved, as client certificate or key files for good.
    public func markIdentityFiles(_ paths: Set<String>, in project: ProjectID) {
        guard !paths.isSubset(of: projectState(project).identityFiles) else {
            return
        }
        updateProject(project) { $0.identityFiles.formUnion(paths) }
    }

    private static func slots(of placed: [PlacedPathReference]) -> [ProjectPathReference: Set<ProjectPathSlot>] {
        placed.reduce(into: [:]) { $0[$1.reference, default: []].insert($1.slot) }
    }

    /// Gives every choice with no slots recorded, made before slots were, the slots `held` lists for its reference.
    private static func slotUnslotted(_ state: inout ProjectWorkspaceState, holding held: [ProjectPathReference: Set<ProjectPathSlot>]) {
        for key in state.localPaths.keys where state.localPathSlots[key] == nil {
            state.localPathSlots[key] = LocalPathID(string: key).flatMap { held[.local($0)] } ?? []
        }
        for path in state.chosenOutsidePaths where state.chosenOutsideSlots[path] == nil {
            state.chosenOutsideSlots[path] = held[.relative(path)] ?? []
        }
    }
}
