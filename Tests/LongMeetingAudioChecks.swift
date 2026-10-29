import Foundation
import AVFoundation
import RingCore

@MainActor func checkLongMeetingAudio(_ check: (Bool, String) -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-hour-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("microphone.caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var file: AVAudioFile? = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var frame: Int64 = 0
    let total: Int64 = 3600 * 16000
    while frame < total {
        let count = min(Int64(4096), total - frame); buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<Int(count) {
            let position = frame + Int64(i)
            buffer.floatChannelData![0][i] = position >= 175 * 16000 && position < 177 * 16000 ? 0 : 0.05
        }
        try file!.write(from: buffer); frame += count
    }
    file = nil
    let stamps = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let sentinel = Data("EXISTING PLAYBACK PART".utf8), playback = folder.appendingPathComponent("part-001.m4a")
    try sentinel.write(to: playback)
    let chunks = try MeetingAudioMixer.transcriptionChunks(folder: folder, completed: [])
    check(chunks.count >= 20 && chunks.allSatisfy { $0.duration <= 180 } && chunks.first?.startFrame == 0 && chunks.last?.endFrame == total,
          "A real one-hour PCM file produces complete uploads bounded to three minutes")
    check(chunks[0].endFrame >= 175 * 16000 && chunks[0].endFrame < 177 * 16000,
          "Audio chunking prefers a quiet boundary near the upload limit")
    check(zip(chunks, chunks.dropFirst()).allSatisfy { $0.endFrame == $1.startFrame },
          "One-hour transcription ranges have no gaps or repeated frames")
    var valid = true
    for chunk in chunks {
        let part = try MeetingAudioMixer.transcriptionPart(folder: folder, chunk: chunk)
        let audio = try AVAudioFile(forReading: part.url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let size = try part.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        valid = valid && abs(duration - chunk.duration) < 0.2 && size > 0 && size < 24_000_000
    }
    check(valid, "Every one-hour upload chunk is readable AAC with accurate duration below the upload cap")
    let first = try MeetingAudioMixer.transcriptionPart(folder: folder, chunk: chunks[0])
    let modified = try first.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    _ = try MeetingAudioMixer.transcriptionPart(folder: folder, chunk: chunks[0])
    check(try first.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified,
          "Retrying a prepared transcription chunk reuses its cached audio")
    check(try Data(contentsOf: playback) == sentinel, "Transcription chunks preserve legacy playback files")
    let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    check(stamps.fileSize == after.fileSize && stamps.contentModificationDate == after.contentModificationDate,
          "Hour-long processing preserves the original recording")
    let remaining = try MeetingAudioMixer.transcriptionChunks(folder: folder, completed: chunks.prefix(6).map(\.id))
    check(remaining.first?.startFrame == chunks[5].endFrame && remaining.last?.endFrame == total,
          "A restarted long-meeting preparation skips completed audio intervals")
}
