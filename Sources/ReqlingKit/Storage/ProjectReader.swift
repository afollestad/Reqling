import Foundation
import ReqlingScriptProtocol

/// Loads a project folder into a `ProjectDocument` plus the `ProjectDiskIndex` saves need.
///
/// Loading is forgiving: an unreadable request or folder file becomes a `ProjectLoadIssue` and is skipped (and its
/// name is never reused), so one bad file from a merge cannot hide the rest of the project. Only a missing file counts
/// as absent; any other read or listing error marks the entry untracked, so a save can never mistake it for free space.
///
/// IDs are settled only once everything is read (`ProjectReader+IDs.swift`), so a file that repeats another file's ID,
/// or states none, can never take an ID that some other file states.
struct ProjectReader {
    struct Result {
        var document: ProjectDocument
        var index: ProjectDiskIndex
        var issues: [ProjectLoadIssue]
        /// The project was written by a newer format; saving it would drop what this version does not understand.
        var isReadOnly: Bool
    }

    let root: URL
    let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// `previous` is the index from the last load or save, when there is one: an ID two files claim stays with the
    /// file that had it then, rather than with whichever sorts first.
    func read(previous: ProjectDiskIndex? = nil) throws -> Result {
        let projectData: Data
        switch readFile(ProjectLayout.projectFile) {
        case .data(let data):
            projectData = data
        case .missing:
            throw ProjectStorageError.notAProject(root)
        case .failed(let error):
            throw error
        }
        let projectFile = try ProjectJSON.decode(ProjectFile.self, from: projectData)
        var state = ReadState(projectID: projectFile.id, previous: previous ?? ProjectDiskIndex())
        state.cache(ProjectLayout.projectFile, raw: projectData, decoded: projectFile)
        state.index.orders[ProjectLayout.requestsDirectory] = projectFile.rootOrder

        var projectScripts = ScriptSet()
        for phase in ScriptPhase.allCases {
            projectScripts[phase] = readScript(ProjectLayout.projectScriptPath(phase), state: &state)
        }
        let storedEnvironments = loadEnvironments(in: ProjectLayout.environmentsDirectory, state: &state)
        let storedNodes = loadChildren(directory: ProjectLayout.requestsDirectory, order: projectFile.rootOrder, state: &state) ?? []
        let scratch = loadScratch(state: &state)
        let environments = settleEnvironments(
            stored: storedEnvironments,
            recovered: scratch.environments,
            order: projectFile.environmentOrder,
            state: &state
        )

        let document = ProjectDocument(
            id: projectFile.id,
            name: projectFile.name,
            formatVersion: projectFile.formatVersion,
            auth: projectFile.auth,
            tls: projectFile.tls,
            grpc: projectFile.grpc,
            scripts: projectScripts,
            defaultEnvironment: environments.defaultEnvironment,
            environments: environments.others,
            items: settleNodes(storedNodes + scratch.nodes, state: &state)
        )
        return Result(
            document: document,
            index: state.index,
            issues: state.issues,
            isReadOnly: projectFile.formatVersion > ProjectDocument.currentFormatVersion
        )
    }

    static let defaultEnvironmentPath = ProjectLayout.join(
        ProjectLayout.environmentsDirectory,
        "\(ProjectLayout.defaultEnvironmentSlug).\(ProjectLayout.jsonExtension)"
    )

    // MARK: - Environments

    /// An environment file as read, before its IDs are settled.
    struct LoadedEnvironment {
        let path: String
        let statedID: EnvironmentID?
        /// Per variable, the ID its entry states; `nil` where the entry has none.
        let statedVariableIDs: [VariableID?]
        let environment: RequestEnvironment
    }

    func loadEnvironments(in directory: String, state: inout ReadState) -> [LoadedEnvironment] {
        var result: [LoadedEnvironment] = []
        for name in listEntries(directory, state: &state) ?? [] {
            let path = ProjectLayout.join(directory, name)
            guard name.hasSuffix(".\(ProjectLayout.jsonExtension)"), !isDirectory(path) else {
                state.index.untrackedPaths.insert(path)
                continue
            }
            guard let data = readTrackedFile(path, state: &state) else {
                continue
            }
            guard let environment = try? ProjectJSON.decode(RequestEnvironment.self, from: data) else {
                state.index.untrackedPaths.insert(path)
                state.issues.append(ProjectLoadIssue(path: path, message: "This environment file could not be read."))
                continue
            }
            let probe = try? ProjectJSON.decode(EnvironmentIDProbe.self, from: data)
            let probedVariables = probe?.variables ?? []
            let statedVariableIDs = environment.variables.enumerated().map { index, variable in
                probedVariables.indices.contains(index) && probedVariables[index].id != nil ? variable.id : nil
            }
            state.cache(path, raw: data, decoded: environment)
            result.append(LoadedEnvironment(
                path: path,
                statedID: probe?.id == nil ? nil : environment.id,
                statedVariableIDs: statedVariableIDs,
                environment: environment
            ))
        }
        return result
    }

    /// A contested environment ID stays with the file that had it before, then with `default.json`, then with the file
    /// named most exactly after its environment (`staging`, then `staging-2`, …), so a copy made in Finder
    /// (`staging copy.json`, or `staging-2.json` from `cp`) never takes the original's ID and, with it, its secrets.
    private func settleEnvironments(
        stored: [LoadedEnvironment],
        recovered: [LoadedEnvironment],
        order: [EnvironmentID],
        state: inout ReadState
    ) -> (defaultEnvironment: RequestEnvironment, others: [RequestEnvironment]) {
        let defaultPath = Self.defaultEnvironmentPath
        var claims = (stored + recovered).map { loaded in
            IDClaim(path: loaded.path, stated: loaded.statedID, preference: [
                loaded.statedID.flatMap { state.previous.environmentPaths[$0] } == loaded.path ? 0 : 1,
                loaded.path == defaultPath ? 0 : 1,
                Self.slugRank(of: loaded.path, named: loaded.environment.name, fallback: "environment")
            ])
        }
        let storedDefault = stored.first { $0.path == defaultPath }
        if storedDefault == nil {
            claims.append(IDClaim(path: defaultPath, stated: nil, preference: []))
            state.issues.append(ProjectLoadIssue(path: defaultPath, message: "The Default environment was missing and has been recreated."))
        }
        let settled = Self.settle(claims) { state.derivedID(for: $0) }

        func build(_ loaded: LoadedEnvironment) -> RequestEnvironment {
            let id = settled.id(for: loaded.path)
            if settled.replaced.contains(loaded.path) {
                state.issues.append(ProjectLoadIssue(path: loaded.path, message: "A duplicate environment ID was replaced.", losesContent: false))
            }
            state.index.environmentPaths[id] = loaded.path
            let variableClaims = loaded.statedVariableIDs.indices.map { index in
                IDClaim(path: "\(loaded.path)#variables/\(index)", stated: loaded.statedVariableIDs[index], preference: [])
            }
            let variableIDs = Self.settle(variableClaims) { state.derivedID(for: $0) }
            let variables = loaded.environment.variables.enumerated().map { index, variable in
                Variable(
                    id: variableIDs.id(for: variableClaims[index].path),
                    key: variable.key,
                    value: variable.value,
                    isEnabled: variable.isEnabled,
                    isSecret: variable.isSecret
                )
            }
            return RequestEnvironment(id: id, name: loaded.environment.name, variables: variables)
        }

        var defaultEnvironment = storedDefault.map(build) ?? RequestEnvironment(id: settled.id(for: defaultPath), name: "")
        defaultEnvironment.name = RequestEnvironment.defaultName
        let others = stored.filter { $0.path != defaultPath }.map(build).sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.id) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs.id) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return (defaultEnvironment, others + recovered.map(build))
    }

    /// How exactly the file's own name matches the slug Reqling would give `name`: 0 for the slug itself, `n` for its
    /// `-n` variant, and `Int.max` for any other name. Among files stating one ID, the lowest is the likely original.
    static func slugRank(of path: String, named name: String, fallback: String) -> Int {
        let fileName = (path as NSString).lastPathComponent
        let jsonSuffix = ".\(ProjectLayout.jsonExtension)"
        let slug = fileName.hasSuffix(jsonSuffix) ? String(fileName.dropLast(jsonSuffix.count)) : fileName
        let base = Slug.make(name, fallback: fallback)
        if slug == base {
            return 0
        }
        guard Slug.isVariant(slug, of: base) else {
            return Int.max
        }
        return Int(slug.dropFirst(base.count + 1)) ?? Int.max
    }

    // MARK: - File access

    enum FileRead {
        case data(Data)
        case missing
        case failed(any Error)
    }

    func readFile(_ relativePath: String) -> FileRead {
        do {
            return .data(try Data(contentsOf: url(relativePath)))
        } catch let error where Self.isMissing(error) {
            return .missing
        } catch {
            return .failed(error)
        }
    }

    /// A listed file's bytes, or `nil` after recording why there are none. A file deleted since the listing is simply
    /// gone; one that exists but cannot be read is untracked so its name stays reserved.
    func readTrackedFile(_ path: String, state: inout ReadState) -> Data? {
        switch readFile(path) {
        case .data(let data):
            return data
        case .missing:
            return nil
        case .failed:
            state.index.untrackedPaths.insert(path)
            state.issues.append(ProjectLoadIssue(path: path, message: "This file could not be read."))
            return nil
        }
    }

    /// A script file's text, or `""` when there is none. One that can't be read, or isn't UTF-8, is untracked with an
    /// issue, so a save refuses to write over it rather than replace what Reqling couldn't show. Its bytes are cached
    /// as they are, since a script's encoding is its text: it round-trips byte for byte.
    func readScript(_ path: String, state: inout ReadState) -> String {
        guard let data = readTrackedFile(path, state: &state) else {
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else {
            state.index.untrackedPaths.insert(path)
            state.issues.append(ProjectLoadIssue(path: path, message: "This script isn't UTF-8 text, so Reqling leaves it alone."))
            return ""
        }
        state.index.diskContents[path] = data
        state.index.contents[path] = data
        return text
    }

    /// The visible entries of `relativeDirectory`, sorted; empty when it does not exist, and `nil` (with the
    /// directory untracked) when it exists but cannot be listed.
    func listEntries(_ relativeDirectory: String, state: inout ReadState) -> [String]? {
        do {
            let names = try fileManager.contentsOfDirectory(atPath: url(relativeDirectory).path)
            return names.filter { !$0.hasPrefix(".") }.sorted()
        } catch let error where Self.isMissing(error) {
            return []
        } catch {
            state.index.untrackedPaths.insert(relativeDirectory)
            state.issues.append(ProjectLoadIssue(path: relativeDirectory, message: "This folder could not be read."))
            return nil
        }
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            return (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissing) ?? false
        }
    }

    func isDirectory(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url(relativePath).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }
}
