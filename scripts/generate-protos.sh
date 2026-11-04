#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

# Regenerates the committed protobuf code and descriptor sets from the `.proto` sources:
#   - Sources/ReqlingKit/GRPC/Reflection/Generated: gRPC server reflection v1 messages, from Protos/. The reflection
#     client sends them under both `grpc.reflection.v1` and the wire-compatible `v1alpha` service names.
#   - Tests/ReqlingKitTests/GRPC/Generated: the codec test messages, the oracle the dynamic codec is checked against.
#   - Tests/ReqlingKitTests/GRPC/Fixtures/codec_test.binpb: the same file's descriptor set, imports included.
# Run it after changing any of those `.proto` files; never edit the generated files by hand.

if ! command -v protoc >/dev/null 2>&1; then
  echo "error: protoc not found; run ./scripts/setup.sh" >&2
  exit 1
fi
wkt_include="$(cd "$(dirname "$(command -v protoc)")/.." && pwd)/include"
if [ ! -f "$wkt_include/google/protobuf/any.proto" ]; then
  echo "error: no well-known types under $wkt_include; reinstall protobuf with ./scripts/setup.sh" >&2
  exit 1
fi

# Built from the pinned swift-protobuf, so generated code always matches the runtime it links against.
swift build --package-path "$repo_root" --product protoc-gen-swift >/dev/null
plugin="$repo_root/.build/debug/protoc-gen-swift"

reflection_out="$repo_root/Sources/ReqlingKit/GRPC/Reflection/Generated"
mkdir -p "$reflection_out"
protoc -I "$repo_root/Protos" -I "$wkt_include" \
  --plugin=protoc-gen-swift="$plugin" \
  --swift_opt=Visibility=Internal --swift_opt=FileNaming=DropPath \
  --swift_out="$reflection_out" \
  grpc/reflection/v1/reflection.proto

fixtures="$repo_root/Tests/ReqlingKitTests/GRPC/Fixtures"
tests_out="$repo_root/Tests/ReqlingKitTests/GRPC/Generated"
mkdir -p "$tests_out"
protoc -I "$fixtures/Protos" -I "$wkt_include" \
  --plugin=protoc-gen-swift="$plugin" \
  --swift_opt=Visibility=Internal --swift_opt=FileNaming=DropPath \
  --swift_out="$tests_out" \
  reqling/test/v1/codec_test.proto
protoc -I "$fixtures/Protos" -I "$wkt_include" \
  --include_imports --descriptor_set_out="$fixtures/codec_test.binpb" \
  reqling/test/v1/codec_test.proto

echo "Regenerated protobuf code and descriptor sets."
