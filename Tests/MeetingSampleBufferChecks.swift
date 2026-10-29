import Foundation
import AVFoundation
import CoreMedia

private enum SampleFixtureError: Error { case coreMedia(OSStatus) }

private func sampleFixture(_ audio: AVAudioPCMBuffer?, format: AVAudioFormat, frames: Int, ready: Bool = true, at: Double = 100) throws -> CMSampleBuffer {
    func require(_ status: OSStatus) throws { if status != noErr { throw SampleFixtureError.coreMedia(status) } }
    var description: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description))
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
        presentationTimeStamp: CMTime(seconds: at, preferredTimescale: 48000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample))
    if let audio {
        try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: audio.audioBufferList))
    }
    if ready { try require(CMSampleBufferSetDataReady(sample!)) }
    return sample!
}

@MainActor func checkMeetingSampleBuffers(_ check: (Bool, String) -> Void) async throws {
    let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800)!
    pcm.frameLength = 4800
    for channel in 0..<2 { for i in 0..<4800 { pcm.floatChannelData![channel][i] = 0.25 } }
    let sample = try sampleFixture(pcm, format: stereo, frames: 4800)
    let decoded = try MeetingAudioSampleDecoder.decode(sample)!
    check(decoded.frameLength == 4800 && decoded.format.channelCount == 2 && decoded.floatChannelData![1][100] == 0.25,
          "Native planar ScreenCaptureKit packets decode both channels with their full frame count")
    var replacement: Float = 0.75
    let changed = CMBlockBufferReplaceDataBytes(with: &replacement, blockBuffer: CMSampleBufferGetDataBuffer(sample)!, offsetIntoDestination: 0, dataLength: MemoryLayout<Float>.size)
    check(changed == noErr && decoded.floatChannelData![0][0] == 0.25,
          "Decoded PCM owns its bytes after the source CMBlockBuffer changes or is released")
    let empty = try sampleFixture(nil, format: stereo, frames: 0)
    let waiting = try sampleFixture(nil, format: stereo, frames: 4800, ready: false)
    check(try MeetingAudioSampleDecoder.decode(empty) == nil && MeetingAudioSampleDecoder.decode(waiting) == nil,
          "Empty and not-ready native audio packets do not interrupt a recording")
    let mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
    let mic = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4410)!; mic.frameLength = 4410
    for i in 0..<4410 { mic.int16ChannelData![0][i] = 8192 }
    let micSample = try sampleFixture(mic, format: mono, frames: 4410)
    let decodedMic = try MeetingAudioSampleDecoder.decode(micSample)!
    check(decodedMic.frameLength == 4410 && decodedMic.int16ChannelData![0][100] == 8192,
          "Interleaved 44.1 kHz microphone packets preserve integer PCM samples")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-native-packets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sink = MeetingAudioSink(folder: folder, origin: 100)
    try await sink.appendSampleBuffer(empty, microphone: true)
    try await sink.appendSampleBuffer(micSample, microphone: true)
    try await sink.appendSampleBuffer(sample, microphone: false)
    // An audio route can change format between callbacks. Keep the same timeline.
    try await sink.appendSampleBuffer(try sampleFixture(pcm, format: stereo, frames: 4800, at: 100.1), microphone: true)
    let stats = await sink.finish()
    check(abs(Double(stats.microphoneFrames) / 16000 - 0.2) < 0.002 && abs(Double(stats.callFrames) / 16000 - 0.1) < 0.002,
          "Native packets survive startup empties and a microphone format change while both tracks save")
}
