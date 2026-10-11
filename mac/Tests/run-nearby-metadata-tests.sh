#!/usr/bin/env bash
set -euo pipefail
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Nearby metadata regressions require a Swift compiler."
    exit 77
fi
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp "$test_root/Tests/NearbyServiceMetadataRegression.swift" "$test_dir/main.swift"
swiftc -swift-version 5 "$test_root/airsync-mac/Core/QuickShare/NearbyServiceMetadata.swift" \
    "$test_root/airsync-mac/Core/Discovery/DiscoveryMetadataPolicy.swift" \
    "$test_dir/main.swift" -o "$test_dir/nearby-metadata-tests"
"$test_dir/nearby-metadata-tests"
