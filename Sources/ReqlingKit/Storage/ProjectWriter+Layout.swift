import Foundation

/// Chooses each item's file name for a save. An item that stays in its folder keeps its current name while that still
/// fits its own name (`get-user` or `get-user-2` for "Get user"), so editing one item never renames its siblings;
/// `keptSlug` makes the one exception, for renames. An item moving in takes its base name or the first free numbered
/// variant, so it never takes a name from an item already there.
///
/// Names are reserved case-insensitively, as the default APFS volume compares them, so a new `health.json` can never
/// land on an unreadable `Health.json`.
struct ProjectSaveLayout {
    let previous: ProjectDiskIndex
    private(set) var nodePaths: [RequestNodeID: String] = [:]
    private(set) var environmentPaths: [EnvironmentID: String] = [:]
    private(set) var childOrder: [RequestNodeID: [String]] = [:]

    init(previous: ProjectDiskIndex) {
        self.previous = previous
    }

    /// Lays out `nodes` under `parentPath` and returns their slugs in order. `previousPath` is where the parent's
    /// directory is before this save (`nil` for a new folder): its unreadable entries are there, and move with it.
    mutating func assignChildren(_ nodes: [RequestNode], parentPath: String, previousPath: String?) -> [String] {
        var used = previousPath.map(untrackedNames(in:)) ?? []
        var slugs: [RequestNodeID: String] = [:]
        for node in nodes {
            guard let path = previous.nodePaths[node.id],
                  (path as NSString).deletingLastPathComponent == previousPath,
                  let existing = keptSlug(
                      at: path,
                      file: node.isFolder ? ProjectLayout.join(path, ProjectLayout.folderFile) : path,
                      base: Self.baseSlug(for: node),
                      name: node.name,
                      used: used
                  ) else {
                continue
            }
            slugs[node.id] = existing
            used.insert(existing.lowercased())
        }
        var order: [String] = []
        for node in nodes {
            let slug = slugs[node.id] ?? Self.claim(Self.baseSlug(for: node), in: &used)
            order.append(slug)
            switch node {
            case .request:
                nodePaths[node.id] = ProjectLayout.join(parentPath, "\(slug).\(ProjectLayout.jsonExtension)")
            case .folder(let folder):
                let path = ProjectLayout.join(parentPath, slug)
                nodePaths[node.id] = path
                childOrder[folder.id] = assignChildren(folder.children, parentPath: path, previousPath: previous.nodePaths[folder.id])
            }
        }
        return keepingUnreadable(in: order, previousPath: previousPath)
    }

    /// Puts unreadable entries' slugs back where the stored order had them, each after the nearest earlier slug still
    /// listed. Dropping them would rewrite a parent file nobody touched, and lose where they belong once fixed.
    private func keepingUnreadable(in order: [String], previousPath: String?) -> [String] {
        guard let previousPath, let stored = previous.orders[previousPath] else {
            return order
        }
        let unreadable = Set(previous.untrackedPaths
            .filter { ($0 as NSString).deletingLastPathComponent == previousPath }
            .map(Self.slug(ofPath:)))
        var result = order
        for (position, slug) in stored.enumerated() where unreadable.contains(slug) && !result.contains(slug) {
            let anchor = stored[..<position].last { result.contains($0) }
            result.insert(slug, at: anchor.flatMap { result.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        }
        return result
    }

    mutating func assignEnvironments(_ environments: [RequestEnvironment], defaultID: EnvironmentID) {
        let directory = ProjectLayout.environmentsDirectory
        environmentPaths[defaultID] = ProjectLayout.join(directory, "\(ProjectLayout.defaultEnvironmentSlug).\(ProjectLayout.jsonExtension)")
        var used = untrackedNames(in: directory)
        used.insert(ProjectLayout.defaultEnvironmentSlug)
        var slugs: [EnvironmentID: String] = [:]
        for environment in environments {
            guard let path = previous.environmentPaths[environment.id],
                  let existing = keptSlug(
                      at: path,
                      file: path,
                      base: Slug.make(environment.name, fallback: "environment"),
                      name: environment.name,
                      used: used
                  ) else {
                continue
            }
            slugs[environment.id] = existing
            used.insert(existing.lowercased())
        }
        for environment in environments {
            let slug = slugs[environment.id] ?? Self.claim(Slug.make(environment.name, fallback: "environment"), in: &used)
            environmentPaths[environment.id] = ProjectLayout.join(directory, "\(slug).\(ProjectLayout.jsonExtension)")
        }
    }

    /// Where each unreadable entry will be once this save has moved folders: entries travel with the folder that holds
    /// them, and those inside a removed folder go to the Trash with it.
    func projectedUntrackedPaths() -> Set<String> {
        let folderIDsByPath = Dictionary(previous.nodePaths.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var projected: Set<String> = []
        for path in previous.untrackedPaths {
            var directory = (path as NSString).deletingLastPathComponent
            var suffix = (path as NSString).lastPathComponent
            var destination: String? = path
            while !directory.isEmpty {
                if let folderID = folderIDsByPath[directory] {
                    destination = nodePaths[folderID].map { ProjectLayout.join($0, suffix) }
                    break
                }
                suffix = ProjectLayout.join((directory as NSString).lastPathComponent, suffix)
                directory = (directory as NSString).deletingLastPathComponent
            }
            if let destination {
                projected.insert(destination)
            }
        }
        return projected
    }

    /// The slug at `path` if its item may keep it: one that still fits `base` and is free, where a numbered variant
    /// counts only while the item's name is unchanged. Otherwise renaming "Staging 2" to "Staging" would stay on
    /// `staging-2.json`, and a copy at `staging.json` would take its ID and secrets on the next launch
    /// (`ProjectReader.slugRank`). A twin whose exact name frees up later stays put, so it keeps that exposure.
    private func keptSlug(at path: String, file: String, base: String, name: String, used: Set<String>) -> String? {
        let existing = Self.slug(ofPath: path)
        guard Slug.isVariant(existing, of: base), !used.contains(existing.lowercased()) else {
            return nil
        }
        guard existing == base || previousName(in: file).map({ $0 == name }) ?? true else {
            return nil
        }
        return existing
    }

    /// The name `file` stated when last read or written; `nil` when nothing was recorded, as for a folder adopted
    /// without a `_folder.json`.
    private func previousName(in file: String) -> String? {
        previous.contents[file].flatMap { try? ProjectJSON.decode(NameProbe.self, from: $0) }?.name
    }

    private static func baseSlug(for node: RequestNode) -> String {
        Slug.make(node.name, fallback: node.isFolder ? "folder" : "request")
    }

    /// `base` or its first free numbered variant, reserved in `used` (which holds lower-cased names).
    private static func claim(_ base: String, in used: inout Set<String>) -> String {
        let slug = Slug.unique(base.lowercased(), avoiding: used)
        used.insert(slug)
        return slug
    }

    private static func slug(ofPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let jsonSuffix = ".\(ProjectLayout.jsonExtension)"
        return name.hasSuffix(jsonSuffix) ? String(name.dropLast(jsonSuffix.count)) : name
    }

    /// Reservations for the unreadable entries directly inside `directory`: lower-cased and without a `.json`
    /// extension, so neither a request (`<slug>.json`) nor a folder (`<slug>`) can take a name that resolves to one.
    /// A script file left untracked reserves the slug it would belong to, so no new request adopts it, unless the
    /// request with that slug is tracked: that one keeps its name.
    private func untrackedNames(in directory: String) -> Set<String> {
        let jsonSuffix = ".\(ProjectLayout.jsonExtension)"
        let requestSlugs = Set(previous.nodePaths.values
            .filter { ($0 as NSString).deletingLastPathComponent == directory && $0.hasSuffix(jsonSuffix) }
            .map { Self.slug(ofPath: $0).lowercased() })
        return Set(previous.untrackedPaths
            .filter { ($0 as NSString).deletingLastPathComponent == directory }
            .compactMap { path in
                let name = (path as NSString).lastPathComponent.lowercased()
                if let owner = ProjectLayout.scriptOwner(ofFileNamed: name) {
                    return requestSlugs.contains(owner.slug) ? nil : owner.slug
                }
                return name.hasSuffix(jsonSuffix) ? String(name.dropLast(jsonSuffix.count)) : name
            })
    }
}

private struct NameProbe: Decodable {
    let name: String?
}
