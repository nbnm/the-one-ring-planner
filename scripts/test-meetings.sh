#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target RingCore
mkdir -p .build/meeting-checks
ring_objects=(.build/debug/RingCore.build/*.o)
swiftc -swift-version 5 -parse-as-library -I .build/debug/Modules Sources/RingPlanner/MeetingAudio.swift Sources/RingPlanner/MeetingAudioResampler.swift Sources/RingPlanner/MeetingSystemAudio.swift Sources/RingPlanner/MeetingPlayback.swift Sources/RingPlanner/MeetingRecorder.swift Sources/RingPlanner/MeetingLocalTranscriber.swift Sources/RingPlanner/SpeechCapture.swift Sources/RingPlanner/OnDeviceSpeechStream.swift Tests/MeetingAudioChecks.swift Tests/MeetingPlaybackChecks.swift Tests/MeetingSampleBufferChecks.swift Tests/LongMeetingAudioChecks.swift Tests/SystemAudioChecks.swift $ring_objects -o .build/meeting-checks/MeetingAudioChecks
if [[ "${1:-}" == "--speech" ]]; then
    fixture_dir=$(mktemp -d /tmp/one-ring-meeting-speech.XXXXXX)
    /usr/bin/say -v Samantha -o "$fixture_dir/english.caf" 'Remember to review the project plan tomorrow morning.'
    /usr/bin/say -v Milena -o "$fixture_dir/russian.caf" 'Нужно проверить план проекта завтра утром.'
    .build/meeting-checks/MeetingAudioChecks "$fixture_dir/english.caf" "$fixture_dir/russian.caf"
else
    .build/meeting-checks/MeetingAudioChecks
fi
