import AVFoundation
import Speech

// Run with synthesized audio, never with recordings or user task data.
@main enum OnDeviceSpeechChecks {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            print("SKIP SpeechAnalyzer requires a supported Mac with macOS 26+")
            return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var failures = 0
        for attempt in 1...2 {
            let stream = OnDeviceSpeechStream()
            var transcript = ""
            var recognitionError: Error?
            let append = try await stream.prepare(locale: "en-US", onStatus: { _ in },
                onTranscript: { transcript = $0 }, onFailure: { recognitionError = $0 })
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { fatalError("Test buffer") }
            while file.framePosition < file.length {
                try file.read(into: buffer)
                try append(buffer)
            }
            try await stream.finish()
            let words = transcript.lowercased().split { !$0.isLetter }.joined(separator: " ")
            let expected = "remember to review the project plan tomorrow morning"
            if recognitionError == nil && words == expected {
                print("PASS Session \(attempt): real on-device transcription, audio conversion, and final words")
            } else {
                print("FAIL Session \(attempt): \(recognitionError?.localizedDescription ?? transcript)")
                failures += 1
            }
            stream.cancel()
        }
        let cancelled = OnDeviceSpeechStream()
        cancelled.cancel()
        do {
            _ = try await cancelled.prepare(locale: "en-US", onStatus: { _ in }, onTranscript: { _ in }, onFailure: { _ in })
            print("FAIL Cancelled setup restarted"); failures += 1
        } catch is CancellationError { print("PASS Cancelled model setup cannot restart a session") }
        print("3 on-device integration checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
