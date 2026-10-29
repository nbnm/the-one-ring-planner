@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import RingCore

struct MeetingAudioStatistics: Sendable {
    var microphoneFrames: Int64 = 0
    var callFrames: Int64 = 0
    var duration: Double { Double(max(microphoneFrames, callFrames)) / 16000 }
}

enum MeetingAudioPacketError: LocalizedError {
    case format, copy(OSStatus)
    var errorDescription: String? {
        switch self {
        case .format: return "The recording received an unsupported audio packet. Try recording again."
        case .copy(let status): return "The recording could not copy an audio packet (Core Media \(status)). Try recording again."
        }
    }
}

enum MeetingAudioSampleDecoder {
    /// ScreenCaptureKit can deliver ready but empty packets while an audio route starts
    /// or goes silent. Own the PCM bytes instead of borrowing a temporary CMBlockBuffer.
    static func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return nil }
        guard frames <= Int(Int32.max), let description = CMSampleBufferGetFormatDescription(sample) else { throw MeetingAudioPacketError.format }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0, format.channelCount > 0, format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw MeetingAudioPacketError.format }
        buffer.frameLength = AVAudioFrameCount(frames)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard result == noErr else { throw MeetingAudioPacketError.copy(result) }
        return buffer
    }
}

/// All file/converter state is confined to queue. Source buffers are copied before a microphone tap returns.
final class MeetingAudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.t1a.planner.meeting.audio", qos: .userInitiated)
    private let folder: URL
    private let origin: Double
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var micFile: AVAudioFile?
    private var callFile: AVAudioFile?
    private let micConverter = MeetingAudioResampler()
    private let callConverter = MeetingAudioResampler()
    private var statistics = MeetingAudioStatistics()
    private var stopped = false
    private var failed = false
    private var lastLevelAt = Date.distantPast
    private var micLevel: Float = 0
    private var callLevel: Float = 0
    var onLevels: (@Sendable (Float, Float, MeetingAudioStatistics) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?
    init(folder: URL, origin: Double) { self.folder = folder; self.origin = origin }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio || { if #available(macOS 15, *) { return outputType == .microphone }; return false }() else { return }
        do {
            try consumeSample(sampleBuffer, microphone: outputType != .audio)
        } catch { report(error) }
    }
    func microphone(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [self] in do { try consume(copy, microphone: true, at: time) } catch { report(error) } }
    }
    func systemAudio(_ buffer: AVAudioPCMBuffer, at time: Double) {
        // Core Audio's callback supplies an owned copy; retain it through queued conversion.
        queue.async { [self] in do { try consume(buffer, microphone: false, at: time) } catch { report(error) } }
    }
    /// Also used by offline integration checks and the clearly marked example recorder.
    func appendSynthetic(_ buffer: AVAudioPCMBuffer, microphone: Bool, at time: Double) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in do { try consume(buffer, microphone: microphone, at: time); continuation.resume() } catch { continuation.resume(throwing: error) } }
        }
    }
    func appendSampleBuffer(_ sample: CMSampleBuffer, microphone: Bool) async throws {
        guard let buffer = try MeetingAudioSampleDecoder.decode(sample) else { return }
        try await appendSynthetic(buffer, microphone: microphone, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    private func consumeSample(_ sample: CMSampleBuffer, microphone: Bool) throws {
        guard !stopped, !failed, let buffer = try MeetingAudioSampleDecoder.decode(sample) else { return }
        try consume(buffer, microphone: microphone, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    func finish() async -> MeetingAudioStatistics {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !stopped && !failed {
                    do {
                        for (buffer, time) in try micConverter.finish() { try write(buffer, microphone: true, at: time) }
                        for (buffer, time) in try callConverter.finish() { try write(buffer, microphone: false, at: time) }
                    } catch { report(error) }
                }
                stopped = true; micFile = nil; callFile = nil
                continuation.resume(returning: statistics)
            }
        }
    }
    private func consume(_ buffer: AVAudioPCMBuffer, microphone: Bool, at time: Double) throws {
        guard !stopped, !failed, buffer.frameLength > 0 else { return }
        let converter = microphone ? micConverter : callConverter
        for (output, time) in try converter.append(buffer, at: time) { try write(output, microphone: microphone, at: time) }
    }
    private func write(_ output: AVAudioPCMBuffer, microphone: Bool, at time: Double) throws {
        var file = microphone ? micFile : callFile
        if file == nil {
            let url = folder.appendingPathComponent(microphone ? "microphone.caf" : "call.caf")
            file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if microphone { micFile = file } else { callFile = file }
        }
        guard let file else { throw MeetingError.storage }
        let written = microphone ? statistics.microphoneFrames : statistics.callFrames
        let target = time.isFinite ? max(0, Int64(((time - origin) * 16000).rounded())) : written
        // Reject implausible timestamps instead of writing hours of silence after a device error.
        guard target <= 4 * 3600 * 16000 + 16000 else { throw MeetingError.validation("The audio clock changed unexpectedly. The saved recording has been stopped.") }
        var gap = max(0, target - written)
        if gap > 0 {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw MeetingError.storage }
            while gap > 0 {
                silence.frameLength = AVAudioFrameCount(min(4096, gap))
                memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                try file.write(from: silence); gap -= Int64(silence.frameLength)
            }
        }
        let overlap = min(Int64(output.frameLength), max(0, written - target))
        if overlap < output.frameLength {
            if overlap > 0 {
                let length = Int(output.frameLength) - Int(overlap)
                memmove(output.floatChannelData![0], output.floatChannelData![0] + Int(overlap), length * MemoryLayout<Float>.size)
                output.frameLength = AVAudioFrameCount(length)
            }
            try file.write(from: output)
        }
        if microphone { statistics.microphoneFrames = file.length } else { statistics.callFrames = file.length }
        let samples = output.floatChannelData![0], count = Int(output.frameLength)
        let rms = count == 0 ? 0 : sqrt((0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(count))
        if microphone { micLevel = min(1, rms * 8) } else { callLevel = min(1, rms * 8) }
        if Date().timeIntervalSince(lastLevelAt) > 0.2 {
            lastLevelAt = Date(); onLevels?(micLevel, callLevel, statistics)
        }
    }
    private func report(_ error: Error) { if !failed && !stopped { failed = true; onFailure?(error) } }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        result.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for i in 0..<min(source.count, destination.count) {
            if let from = source[i].mData, let to = destination[i].mData { memcpy(to, from, Int(source[i].mDataByteSize)) }
        }
        return result
    }
}

struct MeetingAudioPart: Sendable { let id: String; let url: URL; let offset: Double; let duration: Double }
enum MeetingAudioMixer {
    private struct SourceStamp: Codable, Equatable { let name: String; let size: Int; let modified: Date }
    private struct CachedPart: Codable { let id: String; let offset: Double; let duration: Double; let size: Int }
    private struct Cache: Codable { let version: Int; let sources: [SourceStamp]; let parts: [CachedPart] }
    private static func sourceStamps(folder: URL) throws -> [SourceStamp] {
        try ["microphone.caf", "call.caf"].compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MeetingError.storage }
            return SourceStamp(name: name, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
    }
    /// Bounded-memory offline mixing; AAC parts keep even long calls below transcription upload limits.
    static func prepare(folder: URL) throws -> [MeetingAudioPart] {
        let fm = FileManager.default
        let stamps = try sourceStamps(folder: folder), cacheURL = folder.appendingPathComponent("audio-mix-cache.json")
        if !stamps.isEmpty, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2, cache.sources == stamps, !cache.parts.isEmpty {
            let valid = cache.parts.enumerated().allSatisfy { index, part in
                let expectedID = String(format: "part-%03d", index + 1)
                let url = folder.appendingPathComponent(expectedID + ".m4a")
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                return part.id == expectedID && part.offset == Double(index * 1200) && part.duration > 0 && part.duration <= 1200 && values?.isSymbolicLink != true && values?.fileSize == part.size && part.size > 0
            }
            if valid { try Task.checkCancellation(); return cache.parts.map { MeetingAudioPart(id: $0.id, url: folder.appendingPathComponent($0.id + ".m4a"), offset: $0.offset, duration: $0.duration) } }
        }
        let inputs = try ["microphone.caf", "call.caf"].compactMap { name -> AVAudioFile? in
            let url = folder.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) : nil
        }
        guard let length = inputs.map(\.length).max(), length > 0 else { throw MeetingError.validation("No audio samples were captured. Check the selected app or microphone and try a new recording.") }
        let framesPerPart: Int64 = 20 * 60 * 16000
        var result: [MeetingAudioPart] = []
        for partIndex in 0..<Int((length + framesPerPart - 1) / framesPerPart) {
            let offset = Int64(partIndex) * framesPerPart, finish = min(length, offset + framesPerPart)
            let id = String(format: "part-%03d", partIndex + 1), url = folder.appendingPathComponent(String(format: "part-%03d.m4a", partIndex + 1))
            try writeMix(inputs: inputs, start: offset, end: finish, to: url)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 24_000_000 else { throw MeetingError.tooLarge }
            result.append(MeetingAudioPart(id: id, url: url, offset: Double(offset) / 16000, duration: Double(finish - offset) / 16000))
        }
        try Task.checkCancellation()
        guard try sourceStamps(folder: folder) == stamps else { throw MeetingError.validation("Audio changed while preparing playback. Try again after recording stops.") }
        let cached = try result.map { part in CachedPart(id: part.id, offset: part.offset, duration: part.duration, size: try part.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        try JSONEncoder().encode(Cache(version: 2, sources: stamps, parts: cached)).write(to: cacheURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return result
    }

    private struct TranscriptionCache: Codable { var version: Int?; let sources: [SourceStamp]; let start: Int64; let end: Int64; let size: Int }
    static func transcriptionFrameCount(folder: URL) throws -> Int64 {
        _ = try sourceStamps(folder: folder)
        let inputs = try audioInputs(folder: folder)
        guard let length = inputs.map(\.length).max(), length > 0, length <= 4 * 3600 * 16000 + 16000 else {
            throw MeetingError.validation("No valid meeting audio is available. Your original recording is preserved.")
        }
        return length
    }
    private static func audioInputs(folder: URL) throws -> [AVAudioFile] {
        try ["microphone.caf", "call.caf"].compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw MeetingAudioPacketError.format }
            return file
        }
    }
    static func transcriptionChunks(folder: URL, completed: [String]) throws -> [MeetingAudioChunk] {
        let count = try transcriptionFrameCount(folder: folder)
        let inputs = try audioInputs(folder: folder)
        let pending = MeetingChunkPlanner.pending(totalFrames: count, completed: completed)
        var spans: [MeetingAudioChunk] = []
        for chunk in pending {
            if let last = spans.last, last.endFrame == chunk.startFrame { spans[spans.count - 1] = .init(startFrame: last.startFrame, endFrame: chunk.endFrame) }
            else { spans.append(chunk) }
        }
        var result: [MeetingAudioChunk] = []
        for span in spans {
            var cursor = span.startFrame
            while cursor < span.endFrame {
                try Task.checkCancellation()
                let target = min(span.endFrame, cursor + MeetingChunkPlanner.maximumFrames)
                let boundary = target < span.endFrame ? try quietBoundary(inputs: inputs, target: target) : target
                result.append(.init(startFrame: cursor, endFrame: boundary)); cursor = boundary
            }
        }
        return result
    }
    /// Prefer a quiet half-second within the final four seconds, without growing uploads.
    private static func quietBoundary(inputs: [AVAudioFile], target: Int64) throws -> Int64 {
        let start = max(0, target - 4 * 16000), count = Int(target - start), window = 8000
        guard count >= window else { return target }
        var energy = [Float](repeating: 0, count: count)
        for input in inputs where start < input.length {
            input.framePosition = start
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(count), input.length - start)))
            for i in 0..<Int(buffer.frameLength) { let sample = buffer.floatChannelData![0][i]; energy[i] += sample * sample }
        }
        func average(_ a: Int) -> Float { energy[a..<(a + window)].reduce(0, +) / Float(window) }
        var best = average(count - window), boundary = target
        for index in stride(from: 0, through: count - window, by: window / 2) {
            let value = average(index)
            if value < best * 0.8 { best = value; boundary = start + Int64(index + window / 2) }
        }
        return best < 0.0004 ? boundary : target
    }
    /// Separate transcription files keep playback's legacy part IDs and caches intact.
    static func transcriptionPart(folder: URL, chunk: MeetingAudioChunk) throws -> MeetingAudioPart {
        let fm = FileManager.default, stamps = try sourceStamps(folder: folder)
        let inputs = try audioInputs(folder: folder)
        guard chunk.startFrame >= 0, chunk.endFrame > chunk.startFrame, chunk.endFrame <= (inputs.map(\.length).max() ?? 0),
              chunk.endFrame - chunk.startFrame <= MeetingChunkPlanner.maximumFrames else { throw MeetingError.validation("Invalid transcription chunk. Your recording is preserved.") }
        let directory = folder.appendingPathComponent("Transcription", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(chunk.id + ".m4a"), cacheURL = directory.appendingPathComponent(chunk.id + ".json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(TranscriptionCache.self, from: data),
           cached.version == 2, cached.sources == stamps, cached.start == chunk.startFrame, cached.end == chunk.endFrame,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink != true, size.fileSize == cached.size, cached.size > 0 {
            return .init(id: chunk.id, url: url, offset: chunk.offset, duration: chunk.duration)
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? fm.removeItem(at: temporary) }
        try writeMix(inputs: inputs, start: chunk.startFrame, end: chunk.endFrame, to: temporary)
        try Task.checkCancellation()
        guard try sourceStamps(folder: folder) == stamps else { throw MeetingError.validation("Recording audio changed during preparation. Try again after recording stops.") }
        let data = try Data(contentsOf: temporary)
        guard !data.isEmpty, data.count <= 24_000_000 else { throw MeetingError.tooLarge }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try JSONEncoder().encode(TranscriptionCache(version: 2, sources: stamps, start: chunk.startFrame, end: chunk.endFrame, size: data.count)).write(to: cacheURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return .init(id: chunk.id, url: url, offset: chunk.offset, duration: chunk.duration)
    }
    private static func writeMix(inputs: [AVAudioFile], start: Int64, end: Int64, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var output: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for input in inputs { input.framePosition = min(start, input.length) }
        var frame = start
        while frame < end {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, end - frame))
            let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            mixed.frameLength = count; memset(mixed.floatChannelData![0], 0, Int(count) * MemoryLayout<Float>.size)
            for input in inputs where frame < input.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)!
                try input.read(into: buffer, frameCount: min(count, AVAudioFrameCount(input.length - frame)))
                for sample in 0..<Int(buffer.frameLength) { mixed.floatChannelData![0][sample] += buffer.floatChannelData![0][sample] }
            }
            let gain: Float = inputs.count > 1 ? 0.5 : 1
            for sample in 0..<Int(count) { mixed.floatChannelData![0][sample] = max(-1, min(1, mixed.floatChannelData![0][sample] * gain)) }
            try output!.write(from: mixed); frame += Int64(count)
        }
        output = nil
    }
}
