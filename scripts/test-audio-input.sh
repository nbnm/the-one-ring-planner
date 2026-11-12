#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/audio-input-checks
clang -fobjc-arc -fmodules -framework AVFoundation -framework Foundation \
    -I Sources/RingAudioSupport/include Sources/RingAudioSupport/RPAudioInput.m \
    Tests/AudioInputBridgeChecks.m -o .build/audio-input-checks/AudioInputBridgeChecks
.build/audio-input-checks/AudioInputBridgeChecks
