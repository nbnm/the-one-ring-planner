import AVFoundation
import Speech
import RingCore

@MainActor enum MeetingLocalTranscriber {
    static func transcribe(folder: URL, language: MeetingLanguage, onStatus: @escaping (String) -> Void, authorize: () async -> Bool = {
        await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
    }) async throws -> [MeetingSegment] {
        guard #available(macOS 26, *) else { throw MeetingError.validation("Local meeting transcription requires macOS 26. Use the configured LiteLLM audio model on this Mac.") }
        guard let locale = language.locale else { throw MeetingError.validation("Choose English or Russian for local transcription. Automatic mixed-language processing is available through LiteLLM.") }
        guard await authorize() else { throw MeetingError.validation("Allow Speech Recognition in System Settings → Privacy & Security to transcribe locally.") }
        try Task.checkCancellation()
        var result: [MeetingSegment] = []
        for (name, speaker) in [("microphone.caf", "me"), ("call.caf", "call")] {
            let file = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { continue }
            onStatus(speaker == "me" ? "Transcribing your microphone locally…" : "Transcribing call audio locally…")
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
                let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedTranscriptionWithAlternatives)
                result += try await run(transcriber, locale: supported, file: file, speaker: speaker, onStatus: onStatus) { value in
                    (String(value.text.characters), value.range)
                }
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
                let transcriber = DictationTranscriber(locale: supported, preset: .timeIndexedLongDictation)
                result += try await run(transcriber, locale: supported, file: file, speaker: speaker, onStatus: onStatus) { value in
                    (String(value.text.characters), value.range)
                }
            } else { throw MeetingError.validation("This Mac has no local model for \(language.title). Use the configured LiteLLM audio model.") }
        }
        return result.sorted { $0.start < $1.start }
    }
    @available(macOS 26, *) private static func run<M: SpeechModule>(_ module: M, locale: Locale, file: URL, speaker: String,
            onStatus: @escaping (String) -> Void, text: @escaping (M.Result) -> (String, CMTimeRange)) async throws -> [MeetingSegment] {
        try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onStatus("Downloading the \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) local speech model…")
            do { try await install.downloadAndInstall() }
            catch { throw MeetingError.validation("Apple could not install the local \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) speech model. Your audio is preserved. Try again later, or use a LiteLLM audio transcription model.") }
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () throws -> [MeetingSegment] in
            var segments: [MeetingSegment] = []
            for try await result in module.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let (raw, range) = text(result), cleaned = CaptureVocabulary.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                if cleaned.contains(where: { $0.isLetter || $0.isNumber }) {
                    segments.append(MeetingSegment(id: "\(speaker)-\(segments.count)", start: max(0, range.start.seconds), end: max(0, CMTimeRangeGetEnd(range).seconds), speakerID: speaker, text: cleaned))
                }
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                let audio = try AVAudioFile(forReading: file)
                _ = try await analyzer.analyzeSequence(from: audio)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await results.value
            } catch {
                results.cancel(); await analyzer.cancelAndFinishNow(); throw error
            }
        } onCancel: { results.cancel(); Task { await analyzer.cancelAndFinishNow() } }
    }
}
