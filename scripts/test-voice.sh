#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/voice-checks
swiftc -swift-version 5 -parse-as-library Sources/RingPlanner/SpeechCapture.swift Sources/RingPlanner/OnDeviceSpeechStream.swift Tests/VoiceCaptureChecks.swift -o .build/voice-checks/VoiceCaptureChecks
.build/voice-checks/VoiceCaptureChecks
