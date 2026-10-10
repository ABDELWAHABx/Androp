#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 "$test_root/airsync-mac/Core/QuickShare/FileTransferRoutePolicy.swift" \
    "$test_root/Tests/FileTransferRouteRegression.swift" -o "$test_dir/file-route-tests"
"$test_dir/file-route-tests"
