#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/WebSocket/NetworkRecoveryPolicy.swift" \
    "$test_root/Tests/NetworkRecoveryRegression.swift" -o "$test_dir/network-tests"
"$test_dir/network-tests"
