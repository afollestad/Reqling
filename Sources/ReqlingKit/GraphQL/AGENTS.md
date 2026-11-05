## GraphQL

These instructions cover `Sources/ReqlingKit/GraphQL/`: the schema model, its decoding and printing, and introspection. GraphQLSwift itself sits behind `Sources/ReqlingGraphQLEngine/`.

- **Change decoding, printing, or introspection only with the oracle suites in `Tests/ReqlingKitTests/GraphQL/` passing.** They compare against GraphQLSwift executing the fixture schema (`Tools/GraphQLFixtureServer`), which hand-written expectations cannot stand in for.
