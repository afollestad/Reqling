import Foundation

/// A collection or API description mapped to Reqling's model by an importer (`PostmanImporter.plan`), ready for
/// `ProjectLifecycle.importProject` to write as a new project. Every ID in it is fresh. Importers only plan, off the
/// main actor; nothing reaches the library until it's written.
public struct ProjectImport: Sendable {
    /// What the source calls itself, which the project takes unless the person gives another name.
    public let name: String
    let auth: HTTPAuth
    let scripts: ScriptSet
    let items: [RequestNode]
    /// The Default environment's variables: the source's own, then the credentials the import made variables of.
    let defaultVariables: [Variable]
    let environments: [RequestEnvironment]
    /// Variables merged into the library's Global when the project is written, such as a Postman globals export's.
    let globals: [Variable]
    /// Body files found on this Mac, pointed at once the project's folder is known.
    let files: [ImportFileSlot]
    public let notes: [ImportNote]
    public let counts: ImportCounts
    /// The environments the import adds or changes, by name, Default included; Global's is reported when it's written.
    public let environmentChanges: [ImportEnvironmentChange]
    /// Whether any script came along, which decides whether the new project's scripts are trusted.
    public let hasScripts: Bool
}
