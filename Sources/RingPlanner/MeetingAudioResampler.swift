import AVFoundation

/// Keep filter state across packets. Converted packets use the output clock;
/// converter latency must not become a silence gap at every input callback.
final class MeetingAudioResampler {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var nextTime: Double = 0
    private var inputEnd: Double?
    func append(_ buffer: AVAudioPCMBuffer, at time: Double) throws -> [(AVAudioPCMBuffer, Double)] {
        let time = time.isFinite ? time : inputEnd ?? 0
        var output: [(AVAudioPCMBuffer, Double)] = []
        if converter?.inputFormat != buffer.format || inputEnd.map({ abs($0 - time) > 0.005 }) == true {
            output = try finish()
            converter = AVAudioConverter(from: buffer.format, to: format); converter?.primeMethod = .none
            nextTime = time
        }
        inputEnd = time + Double(buffer.frameLength) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 4096
        if let converted = try convert(buffer, capacity: capacity) { output.append(converted) }
        return output
    }
    func finish() throws -> [(AVAudioPCMBuffer, Double)] {
        defer { converter = nil; inputEnd = nil }
        guard converter != nil, let inputEnd else { return [] }
        var result: [(AVAudioPCMBuffer, Double)] = []
        while nextTime < inputEnd - 1.0 / 32000 {
            let remaining = min(4096, max(1, Int(((inputEnd - nextTime) * 16000).rounded())))
            guard let packet = try convert(nil, capacity: AVAudioFrameCount(remaining)) else { break }
            result.append(packet)
        }
        return result
    }
    private func convert(_ input: AVAudioPCMBuffer?, capacity: AVAudioFrameCount) throws -> (AVAudioPCMBuffer, Double)? {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw VoiceCaptureError.conversion }
        var supplied = false, error: NSError?
        let state = converter.convert(to: output, error: &error) { _, status in
            if input == nil { status.pointee = .endOfStream; return nil }
            status.pointee = supplied ? .noDataNow : .haveData
            defer { supplied = true }; return supplied ? nil : input
        }
        if state == .error { throw error ?? VoiceCaptureError.conversion as NSError }
        guard output.frameLength > 0 else { return nil }
        let time = nextTime; nextTime += Double(output.frameLength) / 16000
        return (output, time)
    }
}
