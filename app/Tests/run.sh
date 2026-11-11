#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

mkdir -p .build
sources=()
for source in app/Sources/*.swift; do
    if [[ "$source" != "app/Sources/main.swift" ]]; then
        sources+=("$source")
    fi
done
swiftc -swift-version 5 "${sources[@]}" app/Tests/*.swift -o .build/SerpentisTests
.build/SerpentisTests
