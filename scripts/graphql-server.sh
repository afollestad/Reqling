#!/bin/bash
set -euo pipefail

# Runs the GraphQL fixture server on loopback for trying Reqling's GraphQL features by hand: by default
# http://127.0.0.1:4000/graphql, serving the built-in library schema. Arguments go to the server; see `--help`.
# Usage: ./scripts/graphql-server.sh [--port <port>] [--token <token>] [--no-introspection] [--schema <file.graphql>]
source "$(dirname "$0")/lib/common.sh"

# Built as its own package, in its own folder under .build/, so this never touches the app's or the tests' build.
build=(swift build --package-path Tools/GraphQLFixtureServer --scratch-path .build/graphql-fixture-server
  --only-use-versions-from-resolved-file --product graphql-fixture-server)
run_filtered graphql-server "${build[@]}"
bin_path=$("${build[@]}" --show-bin-path)
exec "$bin_path/graphql-fixture-server" "$@"
