#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCES=()
for source in Sources/*.swift; do
    if [ "$source" != Sources/main.swift ]; then SOURCES+=("$source"); fi
done
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/serpentis-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/serpentis-module-cache" \
    "${SOURCES[@]}" Tests/main.swift -o "$TEST_BUILD/input-tests"
"$TEST_BUILD/input-tests" "$@"
