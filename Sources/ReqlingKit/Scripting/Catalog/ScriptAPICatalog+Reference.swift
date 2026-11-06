import ReqlingScriptProtocol

/// The API reference as Markdown, written from the catalog, so the guide's reference (`docs/scripts.md`, checked by
/// `ScriptAPIReferenceDocsTests`) and MCP's `get_script_reference` never drift from what runs: Reqling's globals, then
/// every type they reach, then how each `pm` name maps to Reqling's.
extension ScriptAPICatalog {
    public static var reference: String {
        standard.reference(globals: reqlingGlobals)
    }

    func reference(globals: [ScriptMember]) -> String {
        var sections = ["### Globals\n\n" + globals.filter { $0.name != "pm" }.map(Self.line).joined(separator: "\n")]
        for type in reachableTypes(from: globals) {
            let note = type.isOpen ? " Lists the most used of its members." : ""
            sections.append("### `\(type.name)`\n\n\(type.summary)\(note)\n\n" + type.members.map(Self.line).joined(separator: "\n"))
        }
        if let postman = self.type("Postman") {
            let lines = postman.members.map { member in
                switch member.availability {
                case .supported: "- `pm.\(member.name)`"
                case .compatibility(let equivalent): "- `pm.\(member.name)`: `\(equivalent)`"
                case .unsupported(let reason): "- `pm.\(member.name)`: not supported, since \(reason)"
                }
            }
            sections.append("### Postman's `pm`\n\nScripts from Postman run as they are. Each name works like its Reqling equivalent:\n\n"
                + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The types `globals` reach through members, parameters, results, and functions' own properties, in the order
    /// they're met; `pm`'s are left to its own section.
    private func reachableTypes(from globals: [ScriptMember]) -> [ScriptType] {
        var queue = globals.filter { $0.name != "pm" }
        var seen: Set<String> = []
        var found: [ScriptType] = []
        while !queue.isEmpty {
            let member = queue.removeFirst()
            let names = [member.type.namedType, Self.element(of: member.type), member.functionType] + member.parameters.map { $0.type.namedType }
            for name in names.compactMap(\.self) where !name.hasPrefix("Postman") && seen.insert(name).inserted {
                if let type = type(name) {
                    found.append(type)
                    queue += type.members
                }
            }
        }
        return found
    }

    private static func element(of type: ScriptValueType) -> String? {
        switch type {
        case .array(let element): element.namedType
        case .optional(let wrapped): element(of: wrapped)
        default: nil
        }
    }

    private static func line(_ member: ScriptMember) -> String {
        var notes: [String] = []
        if member.phases == [.preRequest] {
            notes.append("pre-request")
        } else if member.phases == [.postResponse] {
            notes.append("post-response")
        }
        if let protocols = member.protocols {
            let names = [(ScriptResponseKind.http, "HTTP"), (.grpc, "gRPC"), (.webSocket, "WebSocket")]
                .filter { protocols.contains($0.0) || ($0.0 == .http && protocols.contains(.eventStream)) }
                .map(\.1)
            notes.append(names.joined(separator: " and "))
        }
        let suffix = notes.isEmpty ? "" : " *(\(notes.joined(separator: ", ")) only)*"
        return "- `\(member.signature)`: \(member.summary)\(suffix)"
    }
}
