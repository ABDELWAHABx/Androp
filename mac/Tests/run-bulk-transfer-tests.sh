#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 \
    "$test_root/airsync-mac/Core/Util/FileTransfer/BulkTransferProtocol.swift" \
    "$test_root/Tests/BulkTransferProtocolRegression.swift" -o "$test_dir/bulk-transfer-tests"
"$test_dir/bulk-transfer-tests"
