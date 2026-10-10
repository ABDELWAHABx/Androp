#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/FloatingWidgetPlacement.swift" \
    "$test_root/Tests/FloatingWidgetPlacementRegression.swift" -o "$test_dir/widget-placement-tests"
"$test_dir/widget-placement-tests"
