#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target RingCore
mkdir -p .build/telegram-checks
ring_objects=(.build/debug/RingCore.build/*.o)
swiftc -swift-version 5 -parse-as-library -I .build/debug/Modules Sources/RingPlanner/TelegramAudio.swift Tests/TelegramAudioChecks.swift $ring_objects -o .build/telegram-checks/TelegramAudioChecks
.build/telegram-checks/TelegramAudioChecks
