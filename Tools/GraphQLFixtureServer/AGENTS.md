## GraphQL Fixture Server

These instructions cover `Tools/GraphQLFixtureServer/`: the loopback GraphQL server behind the GraphQL suites in `ReqlingKitTests` and `scripts/graphql-server.sh`. Its pins follow the root's (`AGENTS.md`).

- **Never give this package resources.** Tests build its library into the root's build folder, and `scripts/build.sh` copies every dependency's bundle there into the app.
