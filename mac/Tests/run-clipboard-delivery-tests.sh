#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/ClipboardDeliveryQueue.swift" \
    "$test_root/Tests/ClipboardDeliveryRegression.swift" -o "$test_dir/clipboard-tests"
"$test_dir/clipboard-tests"
