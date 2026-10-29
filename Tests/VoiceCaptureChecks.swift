import Foundation
import Speech

// Permission providers are controlled here; these checks never request actual microphone access.
@main enum VoiceCaptureChecks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS \(name)") }
            else { print("FAIL \(name)"); failures += 1 }
        }
        do {
            var micRequests = 0
            var callbacks = 0
            let service = SpeechCapture(authorizeSpeech: { .denied }, authorizeMicrophone: { micRequests += 1; return false })
            await service.start(locale: "en-US") { _ in callbacks += 1 }
            check(!service.isBusy && micRequests == 0 && callbacks == 0 && service.message != nil, "Permission denial leaves capture idle with a text fallback")
        }
        do {
            var reply: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
            var micRequests = 0
            let service = SpeechCapture(authorizeSpeech: { await withCheckedContinuation { reply = $0 } }, authorizeMicrophone: { micRequests += 1; return true })
            let pending = Task { await service.start(locale: "en-US") { _ in } }
            while reply == nil { await Task.yield() }
            service.stop()
            reply?.resume(returning: .authorized)
            await pending.value
            check(!service.isBusy && micRequests == 0, "Stop cancels a start awaiting speech permission")
        }
        do {
            var reply: CheckedContinuation<Bool, Never>?
            let service = SpeechCapture(authorizeSpeech: { .authorized }, authorizeMicrophone: { await withCheckedContinuation { reply = $0 } })
            let pending = Task { await service.start(locale: "en-US") { _ in } }
            while reply == nil { await Task.yield() }
            service.stop()
            reply?.resume(returning: true)
            await pending.value
            check(!service.isBusy && service.transcript.isEmpty, "A late microphone grant cannot restart a cancelled session")
        }
        do {
            var replies: [CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>] = []
            let service = SpeechCapture(authorizeSpeech: { await withCheckedContinuation { replies.append($0) } }, authorizeMicrophone: { false })
            let first = Task { await service.start(locale: "en-US") { _ in } }
            while replies.isEmpty { await Task.yield() }
            await service.start(locale: "en-US") { _ in }
            let singleRequest = replies.count == 1 && service.isStarting
            service.stop()
            replies.forEach { $0.resume(returning: .denied) }
            await first.value
            check(singleRequest && !service.isBusy, "Repeated starts share one pending permission request")
        }
        let disabled = SpeechCapture.failureMessage(for: NSError(domain: "kLSRErrorDomain", code: 201))
        check(disabled.contains("Dictation is disabled") && disabled.contains("System Settings"), "Legacy Dictation failure explains how to recover")
        let noSpeech = SpeechCapture.failureMessage(for: NSError(domain: "kAFAssistantErrorDomain", code: 1110))
        check(noSpeech.contains("No speech was heard"), "Silent input has an actionable explanation")
        print("6 voice lifecycle checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
