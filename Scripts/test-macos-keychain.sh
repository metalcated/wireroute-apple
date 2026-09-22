#!/bin/bash
set -euo pipefail

# Compile the production implementation and its dependencies under Swift 6.
# This runner intentionally does not read, write, or delete live Keychain items.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/wireroute-keychain-regression.XXXXXX)"
cd "$repo_dir"
xcrun swiftc -swift-version 6 -module-cache-path "$test_dir/modules" \
    Sources/Shared/Keychain.swift \
    Sources/Shared/ActivityMonitor.swift \
    Sources/Shared/FileManager+Extension.swift \
    Sources/WireRouteCore/ActivityMetrics.swift \
    Tests/MacOSKeychainRegression/main.swift \
    -o "$test_dir/keychain-regression"
"$test_dir/keychain-regression"
