#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/voice-checks
VOICE_CHECK_DIR=$(mktemp -d /tmp/one-ring-speech.XXXXXX)
trap 'rm -rf "$VOICE_CHECK_DIR"' EXIT
/usr/bin/say -o "$VOICE_CHECK_DIR/phrase.aiff" 'Remember to review the project plan tomorrow morning.'
# Exercise the same stereo 48 kHz conversion as the default USB microphone.
/usr/bin/afconvert -f WAVE -d LEF32@48000 -c 2 "$VOICE_CHECK_DIR/phrase.aiff" "$VOICE_CHECK_DIR/phrase.wav"
swiftc -swift-version 5 -parse-as-library Tests/LegacyVoiceSupport/OnDeviceSpeechStream.swift Tests/OnDeviceSpeechChecks.swift -o .build/voice-checks/OnDeviceSpeechChecks
.build/voice-checks/OnDeviceSpeechChecks "$VOICE_CHECK_DIR/phrase.wav"
