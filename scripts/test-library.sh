#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target RingCore
mkdir -p .build/library-checks
ring_objects=(.build/debug/RingCore.build/*.o)
swiftc -swift-version 5 -parse-as-library -I .build/debug/Modules \
    Sources/RingPlanner/LibraryMedia.swift Sources/RingPlanner/LibraryTextEditor.swift Tests/LibraryMediaChecks.swift \
    $ring_objects -o .build/library-checks/LibraryMediaChecks
.build/library-checks/LibraryMediaChecks
node --test services/telegram-inbox/worker.test.mjs
