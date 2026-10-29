import Foundation
import AVFoundation
import RingCore

@main enum MeetingAudioChecks {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ value: Bool, _ message: String) { print("\(value ? "PASS" : "FAIL") \(message)"); if !value { failures += 1 } }
        try await checkMeetingSampleBuffers(check)
        try await checkSystemAudioPCM(check)
        try checkLongMeetingAudio(check)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-audio-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        func tone(_ frequency: Double, seconds: Double) -> AVAudioPCMBuffer {
            let count = Int(seconds * format.sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 { for i in 0..<count { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * frequency / 48000) * 0.1) } }
            return buffer
        }
        let sink = MeetingAudioSink(folder: root, origin: 100)
        try await sink.appendSynthetic(tone(220, seconds: 1), microphone: true, at: 100)
        try await sink.appendSynthetic(tone(330, seconds: 1), microphone: false, at: 100.5)
        try await sink.appendSynthetic(tone(220, seconds: 1), microphone: true, at: 102)
        let stats = await sink.finish()
        check(abs(stats.duration - 3) < 0.01, "48 kHz stereo converts to aligned 16 kHz mono with a silence gap")
        let mic = try AVAudioFile(forReading: root.appendingPathComponent("microphone.caf"))
        let call = try AVAudioFile(forReading: root.appendingPathComponent("call.caf"))
        check(mic.length > call.length && abs(Double(call.length) / 16000 - 1.5) < 0.01, "Independent microphone and call timelines preserve source offsets (mic=\(mic.length), call=\(call.length))")
        let buffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: 4000)!
        mic.framePosition = 20000; try mic.read(into: buffer)
        check((0..<Int(buffer.frameLength)).allSatisfy { abs(buffer.floatChannelData![0][$0]) < 0.001 }, "Missing audio stays silent instead of shifting later speech")
        let parts = try MeetingAudioMixer.prepare(folder: root)
        let mixed = try AVAudioFile(forReading: parts[0].url)
        check(parts.count == 1 && abs(parts[0].duration - 3) < 0.01 && mixed.length > 0, "Bounded offline mixing produces playable AAC parts")
        let stamp = try parts[0].url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try MeetingAudioMixer.prepare(folder: root)
        let againStamp = try again[0].url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        check(again.map(\.url) == parts.map(\.url) && againStamp == stamp, "Playback reuses an unchanged audio mix without rewriting a playing file")
        try FileManager.default.removeItem(at: parts[0].url)
        let repaired = try MeetingAudioMixer.prepare(folder: root)
        check(FileManager.default.fileExists(atPath: repaired[0].url.path), "A missing cached audio part is rebuilt from preserved source audio")
        let cacheBefore = try Data(contentsOf: root.appendingPathComponent("audio-mix-cache.json"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: root.appendingPathComponent("microphone.caf").path)
        _ = try MeetingAudioMixer.prepare(folder: root)
        let cacheAfter = try Data(contentsOf: root.appendingPathComponent("audio-mix-cache.json"))
        check(cacheBefore != cacheAfter, "Changing source audio invalidates the prepared playback cache")
        let cache = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("audio-mix-cache.json").path)
        check((cache[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Audio cache metadata stays private on this Mac")
        await checkMeetingPlayback(check)
        let before = stats.microphoneFrames
        try await sink.appendSynthetic(tone(220, seconds: 1), microphone: true, at: 104)
        check(await sink.finish().microphoneFrames == before, "Stopped recordings reject late audio buffers")
        let interrupted = MeetingRecorder(authorizeMicrophone: { false })
        do { try await interrupted.start(folder: root, source: .microphone); check(false, "Denied microphone cannot start recording") }
        catch { check(interrupted.phase == .idle, "Denied microphone returns to idle and explains permissions") }
        let exampleFolder = root.appendingPathComponent("example"); try FileManager.default.createDirectory(at: exampleFolder, withIntermediateDirectories: true)
        let example = MeetingRecorder(authorizeMicrophone: { fatalError("Example must not request real microphone access") })
        try await example.start(folder: exampleFolder, source: .callAndMicrophone, example: true)
        try await Task.sleep(for: .milliseconds(350))
        let recorded = await example.stop()
        check(recorded.microphoneFrames > 0 && recorded.callFrames > 0 && example.phase == .idle, "Example recorder starts, captures both synthetic channels and saves on stop")
        let waiting = MeetingRecorder(authorizeMicrophone: { try? await Task.sleep(for: .milliseconds(200)); return true })
        let preparation = Task { try await waiting.start(folder: exampleFolder, source: .microphone) }
        try await Task.sleep(for: .milliseconds(20)); waiting.cancelPreparation(); preparation.cancel()
        do { try await preparation.value; check(false, "Cancelled setup must not restart") }
        catch { check(waiting.phase == .idle, "Cancelling permission preparation cannot restart the microphone") }
        if CommandLine.arguments.count > 2 {
            for (index, language) in [MeetingLanguage.english, .russian].enumerated() {
                let folder = root.appendingPathComponent(language.rawValue); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let output = try AVAudioFile(forWriting: folder.appendingPathComponent("microphone.caf"), settings: input.fileFormat.settings, commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
                while input.framePosition < input.length { try input.read(into: buffer); try output.write(from: buffer) }
                do {
                    let segments = try await MeetingLocalTranscriber.transcribe(folder: folder, language: language, onStatus: { print($0) }, authorize: { true })
                    let text = segments.map(\.text).joined(separator: " ").lowercased()
                    let matched = language == .english ? text.contains("review") && text.contains("plan") : text.contains("план") && text.contains("завтра")
                    check(matched && segments.allSatisfy { $0.speakerID == "me" && $0.start >= 0 && $0.end >= $0.start }, "Real local \(language.title) transcription and timed channel labels: \(text)")
                } catch { check(false, "Local \(language.title): \(error.localizedDescription)") }
            }
        }
        print("Meeting audio integration: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
