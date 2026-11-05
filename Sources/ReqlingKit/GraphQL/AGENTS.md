## GraphQL

These instructions cover `Sources/ReqlingKit/GraphQL/`: the schema model, its decoding and printing, introspection, loading and caching schemas, and the analysis behind completion, hover, and checking. GraphQLSwift itself sits behind `Sources/ReqlingGraphQLEngine/`.

- **Change decoding, printing, introspection, or analysis only with the oracle suites in `Tests/ReqlingKitTests/GraphQL/` passing.** They compare against GraphQLSwift executing the fixture schema (`Tools/GraphQLFixtureServer`), which hand-written expectations cannot stand in for.
    - Add a query that exercises new syntax to `GraphQLAnalysisOracleTests.corpus`; every name in it is then checked against completion and GraphQLSwift's TypeInfo.
