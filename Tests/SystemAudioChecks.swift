import AVFoundation

@MainActor func checkSystemAudioPCM(_ check: (Bool, String) -> Void) async throws {
    for interleaved in [true, false] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!; buffer.frameLength = 4800
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in buffers.indices {
            let data = buffers[i].mData!.assumingMemoryBound(to: Float.self)
            for sample in 0..<Int(buffers[i].mDataByteSize)/4 { data[sample] = 0.2 }
        }
        let copy = MeetingSystemAudioPCM.copy(buffer.audioBufferList, format: format)
        for i in buffers.indices { memset(buffers[i].mData!, 0, Int(buffers[i].mDataByteSize)) }
        let samples = copy.map { UnsafeMutableAudioBufferListPointer($0.mutableAudioBufferList)[0].mData!.assumingMemoryBound(to: Float.self)[0] }
        check(copy?.frameLength == 4800 && samples == 0.2, "HAL \(interleaved ? "interleaved" : "planar") stereo is copied before its callback storage expires")
        buffer.frameLength = 0
        check(MeetingSystemAudioPCM.copy(buffer.audioBufferList, format: format) == nil, "Empty HAL buffers do not create spurious system audio")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-audio-quality-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
    let sink = MeetingAudioSink(folder: root, origin: 100)
    var frame = 0
    while frame < 44100 {
        let count = min([997, 1231, 701, 4096][(frame / 701) % 4], 44100 - frame)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { buffer.floatChannelData![0][i] = Float(sin(Double(frame + i) * 2 * .pi * 537 / 44100) * 0.2) }
        try await sink.appendSynthetic(buffer, microphone: true, at: 100 + Double(frame) / 44100); frame += count
    }
    _ = await sink.finish()
    let file = try AVAudioFile(forReading: root.appendingPathComponent("microphone.caf"))
    let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!; try file.read(into: audio)
    let samples = audio.floatChannelData![0]
    let error = (-64...64).map { delay in
        sqrt((200..<min(15800, Int(audio.frameLength))).reduce(0.0) { sum, i in
            let delta = Double(samples[i]) - sin(Double(i + delay) * 2 * .pi * 537 / 16000) * 0.2
            return sum + delta * delta
        } / 15600)
    }.min()!
    check(abs(file.length - 16000) <= 2 && error < 0.005, "Variable 44.1 kHz packets retain one continuous waveform and flush the final resampler tail (RMS error \(error))")
    let mixing = root.appendingPathComponent("mix"); try FileManager.default.createDirectory(at: mixing, withIntermediateDirectories: true)
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    for name in ["microphone.caf", "call.caf"] {
        var output: AVAudioFile? = try AVAudioFile(forWriting: mixing.appendingPathComponent(name), settings: mono.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16000)!; buffer.frameLength = 16000
        for i in 0..<16000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 800 / 16000) * 0.9) }
        try output!.write(from: buffer); output = nil
    }
    let mixed = try MeetingAudioMixer.prepare(folder: mixing)
    let decoded = try AVAudioFile(forReading: mixed[0].url)
    let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!; try decoded.read(into: buffer)
    let rms = sqrt((1000..<15000).reduce(0.0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) } / 14000)
    check(rms > 0.55 && rms < 0.72, "Two loud channels mix with headroom instead of hard clipping (RMS \(rms))")
}
