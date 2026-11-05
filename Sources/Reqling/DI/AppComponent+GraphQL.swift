import Foundation
import ReqlingKit

/// GraphQL schemas, shared by the editor, the schema browser, and the MCP tools. An ephemeral (test or screenshot)
/// profile introspects nothing, so opening a GraphQL request there never reaches the network; schema files still load.
@MainActor
extension AppComponent {
    var graphQLSchemas: GraphQLSchemaService {
        shared {
            let fetcher: any GraphQLIntrospectionFetching = storageProfile.isEphemeral
                ? OfflineGraphQLIntrospectionFetcher()
                : LiveGraphQLIntrospectionFetcher()
            return GraphQLSchemaService(store: GraphQLSchemaStore(directory: storageProfile.graphQLSchemasDirectory), fetcher: fetcher)
        }
    }
}
