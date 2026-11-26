#!/usr/bin/env bash
# Regenerates Sources/UURemoteKit/Protocol/Generated from Protos/ with protoc
# and the protoc-gen-swift of the resolved swift-protobuf checkout.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
command -v protoc >/dev/null || { echo "protoc is not installed (brew install protobuf)" >&2; exit 1; }

swift package resolve
checkout="$root/.build/checkouts/swift-protobuf"
swift build -c release --package-path "$checkout" --product protoc-gen-swift
plugin="$checkout/.build/release/protoc-gen-swift"

out="$root/Sources/UURemoteKit/Protocol/Generated"
mkdir -p "$out"
protoc \
    --plugin=protoc-gen-swift="$plugin" \
    --swift_out="$out" \
    --proto_path="$root/Protos" \
    "$root"/Protos/*.proto
