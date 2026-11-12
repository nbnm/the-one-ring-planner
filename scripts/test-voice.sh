#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/voice-checks
swift build --target RingAudioSupport
audio_objects=(.build/debug/RingAudioSupport.build/*.o)
swiftc -swift-version 5 -parse-as-library -I .build/debug/RingAudioSupport.build Sources/RingPlanner/SpeechCapture.swift Sources/RingPlanner/OnDeviceSpeechStream.swift Tests/VoiceCaptureChecks.swift $audio_objects -o .build/voice-checks/VoiceCaptureChecks
.build/voice-checks/VoiceCaptureChecks
