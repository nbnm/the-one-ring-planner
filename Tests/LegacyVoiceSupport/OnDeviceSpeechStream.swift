import AVFoundation
import Speech

// Keep the macOS 14 fallback without storing macOS 26-only types in the coordinator.
@MainActor protocol SpeechStreaming: AnyObject {
    func prepare(locale: String, onStatus: @escaping (String) -> Void,
                 onTranscript: @escaping (String) -> Void,
                 onFailure: @escaping (Error) -> Void) async throws -> (AVAudioPCMBuffer) throws -> Void
    func finish() async throws
    func cancel()
}

enum VoiceCaptureError: LocalizedError {
    case unsupportedLanguage, audioFormat, noInput, conversion
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "On-device speech is unavailable for this language. Choose another speech language in Settings or type your task."
        case .audioFormat: return "The speech model is not ready. Connect to the internet to download it, then try again."
        case .noInput: return "No microphone input is available. Check your input device in System Settings → Sound."
        case .conversion: return "Could not read microphone audio. Check your input device in System Settings → Sound, then try again."
        }
    }
}

@available(macOS 26.0, *)
@MainActor final class OnDeviceSpeechStream: SpeechStreaming {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Error>?
    private var cancelled = false

    func prepare(locale: String, onStatus: @escaping (String) -> Void,
                 onTranscript: @escaping (String) -> Void,
                 onFailure: @escaping (Error) -> Void) async throws -> (AVAudioPCMBuffer) throws -> Void {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw VoiceCaptureError.unsupportedLanguage
        }
        try checkActive()
        // false means this locale was already reserved, which is also ready to use.
        try await AssetInventory.reserve(locale: locale)
        try checkActive()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber
        let installed = await SpeechTranscriber.installedLocales
        try checkActive()
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            onStatus("Downloading on-device speech model…")
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try checkActive()
                try await installation.downloadAndInstall()
            }
        }
        try checkActive()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceCaptureError.audioFormat
        }
        try checkActive()
        onStatus("Preparing microphone…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try checkActive()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        results = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard !cancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal { finalized += text }
                    let transcript = finalized + (result.isFinal ? "" : text)
                    // The model can emit punctuation for silence; it is not a captured thought.
                    if transcript.contains(where: { $0.isLetter || $0.isNumber }) { onTranscript(transcript) }
                }
            } catch {
                if !cancelled && !Task.isCancelled { onFailure(error) }
                throw error
            }
        }
        try await analyzer.start(inputSequence: stream)
        try checkActive()
        // Convert and copy inside the audio tap, before AVAudioEngine reuses its buffer.
        let converter = SpeechAudioConverter(format: format)
        return { buffer in
            let converted = try converter.convert(buffer)
            if converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    func finish() async throws {
        input?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await results?.value
    }

    func cancel() {
        cancelled = true
        input?.finish(); input = nil
        results?.cancel(); results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil; transcriber = nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }
}

// Used only serially by the microphone tap (or the file-based integration check).
final class SpeechAudioConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    init(format: AVAudioFormat) { self.format = format }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw VoiceCaptureError.conversion }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, capacity)) else {
            throw VoiceCaptureError.conversion
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = supplied ? .noDataNow : .haveData
            defer { supplied = true }
            return supplied ? nil : buffer
        }
        if status == .error { throw error ?? VoiceCaptureError.conversion as NSError }
        return output
    }
}
