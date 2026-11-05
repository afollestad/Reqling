import Foundation
internal import ReqlingGraphQLEngine

extension GraphQLTypeSystem {
    /// Reads a schema file: a saved introspection result (`.json`, with or without its `{"data": …}` wrapper) or SDL
    /// (`.graphql`, `.graphqls`, `.gql`). The content decides, not the extension: JSON starts with `{`, and SDL never
    /// does. SDL is introspected through GraphQLSwift, so both decode the same way a server's response does.
    public static func loading(schemaFile data: Data) async throws(GraphQLSchemaError) -> Decoded {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        let firstCharacter = bytes.first { !whitespace.contains($0) }
        if firstCharacter == UInt8(ascii: "{") {
            do {
                return try decoding(introspection: Data(bytes))
            } catch {
                throw GraphQLSchemaError(error.localizedDescription)
            }
        }
        guard let sdl = String(data: Data(bytes), encoding: .utf8) else {
            throw GraphQLSchemaError("The schema file is neither JSON nor UTF-8 text.")
        }
        let json: Data
        let engineIssues: [String]
        do {
            (json, engineIssues) = try await GraphQLEngine.introspection(ofSDL: sdl, query: GraphQLIntrospection.query(.all))
        } catch {
            throw GraphQLSchemaError(error.message)
        }
        do {
            var decoded = try decoding(introspection: json)
            decoded.issues = engineIssues + decoded.issues
            return decoded
        } catch {
            throw GraphQLSchemaError(error.localizedDescription)
        }
    }
}
