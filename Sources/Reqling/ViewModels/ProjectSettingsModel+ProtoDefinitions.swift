import Foundation
import ReqlingKit
import UniformTypeIdentifiers

/// The project's proto definitions. The draft saves with the rest of the sheet, and the workspace status shown beside
/// it is the saved configuration's, so the sheet never compiles a draft the user may still cancel.
extension ProjectSettingsModel {
    /// What saving writes to `document.grpc`: blank entry files dropped and duplicates removed in order, so an empty
    /// row the user left behind cannot narrow the compile to nothing.
    var grpcConfiguration: ProjectGRPCConfiguration {
        let files = protoEntryFiles.map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ProjectGRPCConfiguration(
            protoRoots: protoRoots.uniqued(),
            protoFiles: files.uniqued(),
            descriptorSets: descriptorSets.uniqued()
        )
    }

    /// Whether the draft differs from what the workspace compiles, so the sheet can say its status is not the draft's.
    var hasUnsavedProtoChanges: Bool {
        grpcConfiguration != (app.library.document(projectID)?.grpc ?? ProjectGRPCConfiguration())
    }

    /// The saved configuration's compile status; `nil` while the project has no workspace (no proto definitions saved).
    var workspaceStatus: ProtoWorkspace.Status? {
        app.protoWorkspaces.workspace(for: projectID)?.status
    }

    /// Files the last compile skipped (unsafe names a shared project can't pass to protoc), alongside a status that
    /// may still be ready.
    var workspaceWarnings: [ProtocDiagnostic] {
        app.protoWorkspaces.workspace(for: projectID)?.warnings ?? []
    }

    var protocTooling: ProtocToolingModel {
        app.protocTooling
    }

    func recompileProtos() {
        app.protoWorkspaces.workspace(for: projectID)?.recompile()
    }

    func sharing(of reference: ProjectPathReference) -> PathSharing {
        switch reference {
        case .relative: .shared
        case .local: .thisMacOnly
        }
    }

    // MARK: - Proto roots

    func addProtoRoot() {
        guard let url = app.system.chooseDirectory(prompt: "Add Proto Root"),
              let reference = newReference(for: url, notIn: protoRoots) else {
            return
        }
        protoRoots.append(reference)
    }

    func removeProtoRoot(at index: Int) {
        guard protoRoots.indices.contains(index) else {
            return
        }
        protoRoots.remove(at: index)
    }

    // MARK: - Entry files

    func addEntryFile() {
        protoEntryFiles.append(ProtoEntryFile(path: ""))
    }

    /// Writes by ID, never position: a late commit from a removed row (an input method finishing as focus leaves) is
    /// dropped instead of landing on the row that took its place.
    func setEntryFilePath(_ path: String, for id: ProtoEntryFile.ID) {
        guard let index = protoEntryFiles.firstIndex(where: { $0.id == id }), protoEntryFiles[index].path != path else {
            return
        }
        protoEntryFiles[index].path = path
    }

    func removeEntryFile(_ id: ProtoEntryFile.ID) {
        protoEntryFiles.removeAll { $0.id == id }
    }

    // MARK: - Descriptor sets

    func addDescriptorSet() {
        let types = ["protoset", "binpb", "pb"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Add Descriptor Set", allowedTypes: types),
              let reference = newReference(for: url, notIn: descriptorSets) else {
            return
        }
        descriptorSets.append(reference)
    }

    func removeDescriptorSet(at index: Int) {
        guard descriptorSets.indices.contains(index) else {
            return
        }
        descriptorSets.remove(at: index)
    }

    /// `url` as a reference to append, or `nil` when the pick was cancelled or `url` is already in `existing`.
    ///
    /// The repeat check compares resolved paths before `AppModel.reference(for:in:)` runs, because that mints a fresh
    /// `LocalPathID` for every this-Mac pick: comparing references afterwards would miss the repeat, add a second row,
    /// and orphan a local-path entry. Checking first also skips the shared-or-this-Mac question for a repeat.
    private func newReference(for url: URL, notIn existing: [ProjectPathReference]) -> ProjectPathReference? {
        let target = Self.canonicalPath(url)
        let resolver = app.pathResolver(for: projectID)
        guard !existing.contains(where: { resolver?.url(for: $0).map(Self.canonicalPath) == target }),
              let reference = app.reference(for: url, in: projectID),
              !existing.contains(reference) else {
            return nil
        }
        return reference
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// One entry file row. Rows carry their own identity because paths repeat and change while typed; keying text fields
/// by index or by path would hand a row's focus and edits to its neighbour after a removal.
struct ProtoEntryFile: Identifiable, Equatable {
    let id = UUID()
    var path: String
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
