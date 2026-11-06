## gRPC

These instructions cover `Sources/ReqlingKit/GRPC/`: descriptors, the dynamic codec, protoc tooling, proto workspaces, the executor, and reflection.

- **Never hand-edit generated code.** `Reflection/Generated/` and the test oracle in `Tests/ReqlingKitTests/GRPC/Generated/` come from `scripts/generate-protos.sh`, built with the pinned swift-protobuf; change the `.proto` and rerun it.
- **Test every codec change against the oracle in both directions.** Encode and compare with the SwiftProtobuf-generated type parsing the same JSON, and decode bytes it serialized; hand-written expectations miss proto3 JSON corner cases.
- **Use the Posix (NIOSSL) transport, never TransportServices**; `Sources/ReqlingKit/TLS/AGENTS.md` owns the rule.
- **Build protoc arguments only in `ProtocImporter.compile`.** It vets every path a shared project supplies (`ProtocArguments`); protoc reads `-`/`@` names as options and splits proto paths on `:`, so an invocation built elsewhere lets a cloned repository inject them.
- **Inject process launches, downloads, and file-system changes** (`CommandRunner`, `ProtocDownloader`, the workspace change stream), so tests stay CI-safe; only the importer and workspace suites run the real `protoc` that `scripts/setup.sh` installs.
