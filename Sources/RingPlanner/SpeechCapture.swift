import SwiftUI
import Speech
import AVFoundation
import OSLog
import RingAudioSupport

@MainActor final class SpeechCapture: ObservableObject {
    static var microphoneReservedForMeeting = false
    @Published var recording = false
    @Published var isStarting = false
    @Published var isFinishing = false
    @Published var status = "Preparing microphone…"
    @Published var transcript = ""
    @Published var message: String?
    var isBusy: Bool { isStarting || recording || isFinishing }
    private let microphone = RPAudioInput()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var stream: (any SpeechStreaming)?
    private var timeout: Task<Void, Never>?
    private var finalization: Task<Void, Never>?
    private var sessionID: UUID?
    private var onTranscript: ((String) -> Void)?
    private var onFinished: ((String) -> Void)?
    private let logger = Logger(subsystem: "com.t1a.the-one-ring-planner", category: "VoiceCapture")
    private let authorizeSpeech: @MainActor () async -> SFSpeechRecognizerAuthorizationStatus
    private let authorizeMicrophone: @MainActor () async -> Bool
    init(
        authorizeSpeech: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        },
        authorizeMicrophone: @escaping @MainActor () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.authorizeSpeech = authorizeSpeech; self.authorizeMicrophone = authorizeMicrophone
    }
    func start(locale: String, onTranscript: @escaping (String) -> Void, onFinished: @escaping (String) -> Void = { _ in }) async {
        guard !isBusy else { return }
        guard !Self.microphoneReservedForMeeting else { message = "The microphone is reserved for a meeting recording. Stop the meeting before starting Inbox dictation."; return }
        let id = UUID()
        sessionID = id; isStarting = true; message = nil; status = "Preparing microphone…"
        defer { if sessionID == id { isStarting = false } }
        let speechPermission = await authorizeSpeech()
        guard sessionID == id else { return }
        guard speechPermission == .authorized else {
            message = "Allow Speech Recognition for The One Ring Planner in System Settings → Privacy & Security, then try again."
            stop(); return
        }
        let micPermission = await authorizeMicrophone()
        guard sessionID == id else { return }
        guard micPermission else {
            message = "Allow Microphone access for The One Ring Planner in System Settings → Privacy & Security, then try again."
            stop(); return
        }
        transcript = ""; self.onTranscript = onTranscript; self.onFinished = onFinished
        microphone.onFailure = { [weak self] error in
            Task { @MainActor in self?.fail(error, session: id) }
        }
        do {
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                // SpeechAnalyzer runs locally and does not require Siri/Dictation to be enabled.
                let stream = OnDeviceSpeechStream()
                self.stream = stream
                let append = try await stream.prepare(locale: locale, onStatus: { [weak self] status in
                    guard self?.sessionID == id else { return }; self?.status = status
                }, onTranscript: { [weak self] text in
                    self?.receive(text, session: id)
                }, onFailure: { [weak self] error in
                    self?.fail(error, session: id)
                })
                guard sessionID == id else { stream.cancel(); return }
                try startMicrophone { [weak self] buffer in
                    do { try append(buffer) }
                    catch { Task { @MainActor in self?.fail(error, session: id) } }
                }
            } else {
                try startLegacy(locale: locale, session: id)
            }
            guard sessionID == id else { return }
            recording = true; isStarting = false
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.sessionID == id else { return }
                self.message = "60-second limit reached. Review your transcript before saving."
                self.finish()
            }
        } catch {
            if sessionID == id { fail(error, session: id) }
        }
    }

    // Stop listening immediately, but let the recognizer deliver the last words.
    func finish() {
        if isStarting { stop(); return }
        guard recording, let id = sessionID else { return }
        recording = false; isFinishing = true
        stopMicrophone(); timeout?.cancel()
        request?.endAudio()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.message = "Transcription took too long. Your available transcript is preserved."
            self.stop()
        }
        if let stream {
            finalization = Task { [weak self] in
                do {
                    try await stream.finish()
                    self?.complete(session: id)
                } catch { self?.fail(error, session: id) }
            }
        } else { recognition?.finish() }
    }

    // Cancel pending permission/model setup and ignore callbacks from old sessions.
    func stop() {
        sessionID = nil; recording = false; isStarting = false; isFinishing = false
        timeout?.cancel(); timeout = nil
        finalization?.cancel(); finalization = nil
        stopMicrophone()
        stream?.cancel(); stream = nil
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil; recognizer = nil; onTranscript = nil; onFinished = nil
    }
    func clear() {
        guard !isBusy else { return }
        transcript = ""; message = nil
    }

    private func receive(_ text: String, session id: UUID) {
        guard sessionID == id, text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        transcript = text; onTranscript?(text)
    }
    private func complete(session id: UUID) {
        guard sessionID == id else { return }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "No speech was heard. Check your microphone input and try again."
        }
        let finished = onFinished
        let text = transcript
        stop()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finished?(text) }
    }
    private func fail(_ error: Error, session id: UUID) {
        guard sessionID == id else { return }
        let detail = error as NSError
        logger.error("Speech capture failed: \(detail.domain, privacy: .public) \(detail.code, privacy: .public)")
        message = Self.failureMessage(for: error)
        stop()
    }
    static func failureMessage(for error: Error) -> String {
        let detail = error as NSError
        if detail.domain == "kLSRErrorDomain", detail.code == 201 {
            return "macOS Dictation is disabled. Turn on Dictation in System Settings → Keyboard → Dictation, then try again."
        }
        if detail.domain == "kLSRErrorDomain", detail.code == 102 {
            return "The speech language is not installed. Add it in System Settings → Keyboard → Dictation, then try again."
        }
        if detail.domain == "kAFAssistantErrorDomain", detail.code == 1110 {
            return "No speech was heard. Check your microphone input and try again."
        }
        if let error = error as? VoiceCaptureError { return error.localizedDescription }
        return "Voice capture stopped: \(detail.localizedDescription) Your available transcript is preserved."
    }

    private func startMicrophone(append: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try microphone.start(withBufferSize: 1024) { buffer, _ in append(buffer) }
    }
    private func stopMicrophone() {
        microphone.stop()
    }
    private func startLegacy(locale: String, session id: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw VoiceCaptureError.unsupportedLanguage }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        self.request = request
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if let result { self.receive(result.bestTranscription.formattedString, session: id) }
                if result?.isFinal == true { self.complete(session: id) }
                else if let error { self.fail(error, session: id) }
            }
        }
        try startMicrophone { buffer in request.append(buffer) }
    }
}
