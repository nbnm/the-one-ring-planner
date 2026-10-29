import SwiftUI
import AVFoundation
import ScreenCaptureKit
import RingCore

@MainActor final class MeetingRecorder: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    enum Phase { case idle, preparing, recording, stopping }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "Ready"
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var microphoneHeard = false
    @Published private(set) var callHeard = false
    var isBusy: Bool { phase != .idle }
    var onInterruption: ((Error) -> Void)?
    private var stream: SCStream?
    private var systemAudio: MeetingSystemAudioCapture?
    private var engine: AVAudioEngine?
    private var sink: MeetingAudioSink?
    private var pickerReply: CheckedContinuation<SCContentFilter, Error>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var startedAt: Date?
    private var example = false
    private var exampleTask: Task<Void, Never>?
    private let authorizeMicrophone: @MainActor () async -> Bool
    init(authorizeMicrophone: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.authorizeMicrophone = authorizeMicrophone
    }
    func start(folder: URL, source: MeetingAudioSource, example: Bool = false) async throws {
        guard phase == .idle else { throw MeetingError.validation("A meeting is already recording.") }
        generation = UUID(); let id = generation
        phase = .preparing; status = "Preparing recording…"; elapsed = 0
        microphoneHeard = false; callHeard = false; self.example = example
        do {
            let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard capacity > 512 * 1024 * 1024 else { throw MeetingError.validation("Free at least 512 MB of disk space before recording a meeting.") }
            if source.includesMicrophone && !example {
                guard await authorizeMicrophone() else { throw MeetingError.validation("Allow Microphone access for The One Ring Planner in System Settings → Privacy & Security.") }
                try check(id)
            }
            var filter: SCContentFilter?
            if source.includesCall && !source.usesSystemAudio && !example {
                status = "Choose your call application in the macOS picker…"
                filter = try await chooseApplication()
                try check(id)
            }
            let origin = example ? 0 : CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let sink = MeetingAudioSink(folder: folder, origin: origin)
            self.sink = sink
            sink.onLevels = { [weak self] microphone, call, stats in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.microphoneLevel = microphone; self.callLevel = call
                    self.microphoneHeard = stats.microphoneFrames > 0; self.callHeard = stats.callFrames > 0
                }
            }
            sink.onFailure = { [weak self] error in Task { @MainActor in guard self?.generation == id else { return }; self?.onInterruption?(error) } }
            if example {
                exampleTask = Task { [weak self] in
                    var frame: Int64 = 0
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    while !Task.isCancelled {
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
                        buffer.frameLength = 1600
                        for i in 0..<1600 { buffer.floatChannelData![0][i] = Float(sin(Double(frame + Int64(i)) * 2 * .pi * 220 / 16000)) * 0.08 }
                        do {
                            if source.includesMicrophone { try await sink.appendSynthetic(buffer, microphone: true, at: Double(frame) / 16000) }
                            if source.includesCall { try await sink.appendSynthetic(buffer, microphone: false, at: Double(frame) / 16000) }
                        } catch { self?.onInterruption?(error); break }
                        frame += 1600
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } else if source.usesSystemAudio {
                guard #available(macOS 14.2, *) else { throw MeetingError.validation("System audio recording requires macOS 14.2 or later. Choose a selected-app source on this Mac.") }
                status = "Starting system audio…"
                let capture = MeetingSystemAudioCapture(); systemAudio = capture
                try capture.start(sink: sink); try check(id)
                if source.includesMicrophone { try startMicrophone(sink) }
            } else if let filter {
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3; config.showsCursor = false
                config.capturesAudio = true; config.sampleRate = 48000; config.channelCount = 2; config.excludesCurrentProcessAudio = true
                // Capture the microphone independently. ScreenCaptureKit's microphone
                // packets vary with audio routes and can be empty on Bluetooth devices.
                if #available(macOS 15, *) { config.captureMicrophone = false }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                // ScreenCaptureKit supplies tiny disposable frames for its stream; no image/video is stored.
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                try await stream.startCapture()
                try check(id)
                if source.includesMicrophone { try startMicrophone(sink) }
            } else { try startMicrophone(sink) }
            try check(id)
            phase = .recording; status = example ? "Example audio · no microphone or call is being captured" : "Recording audio locally"
            startedAt = Date()
            timer = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    self.elapsed = Date().timeIntervalSince(self.startedAt ?? Date()); ticks += 1
                    if self.elapsed >= 4 * 3600 { self.onInterruption?(MeetingError.validation("The four-hour recording limit was reached. Saved audio is ready for processing.")); return }
                    if ticks % 20 == 0 {
                        if let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, available < 100 * 1024 * 1024 {
                            self.onInterruption?(MeetingError.validation("Recording stopped because disk space is low. Existing audio is preserved.")); return
                        }
                    }
                }
            }
        } catch {
            _ = await stop(); throw error
        }
    }
    func stop() async -> MeetingAudioStatistics {
        guard phase != .idle else { return MeetingAudioStatistics() }
        phase = .stopping; status = "Saving recording…"; generation = UUID()
        timer?.cancel(); timer = nil; exampleTask?.cancel(); await exampleTask?.value; exampleTask = nil
        cancelPicker()
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
        if let stream { try? await stream.stopCapture() }; stream = nil
        systemAudio?.stop(); systemAudio = nil
        let result = await sink?.finish() ?? MeetingAudioStatistics()
        sink = nil; startedAt = nil; microphoneLevel = 0; callLevel = 0
        SCContentSharingPicker.shared.remove(self); SCContentSharingPicker.shared.isActive = false
        phase = .idle; status = "Saved locally"; elapsed = max(elapsed, result.duration)
        return result
    }
    func cancelPreparation() { generation = UUID(); cancelPicker() }
    private func startMicrophone(_ sink: MeetingAudioSink) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { throw VoiceCaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            sink.microphone(buffer, at: AVAudioTime.seconds(forHostTime: time.hostTime))
        }
        self.engine = engine; engine.prepare(); try engine.start()
    }
    private func check(_ id: UUID) throws { try Task.checkCancellation(); if generation != id { throw CancellationError() } }
    private func chooseApplication() async throws -> SCContentFilter {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pickerReply = continuation
                let picker = SCContentSharingPicker.shared
                var config = SCContentSharingPickerConfiguration()
                config.allowedPickerModes = [.singleApplication]
                config.allowsChangingSelectedContent = false
                config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "com.t1a.the-one-ring-planner"]
                picker.defaultConfiguration = config; picker.add(self); picker.isActive = true
                picker.present()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelPicker() } }
    }
    private func cancelPicker() { let reply = pickerReply; pickerReply = nil; reply?.resume(throwing: CancellationError()) }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.cancelPicker() }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in let reply = self?.pickerReply; self?.pickerReply = nil; reply?.resume(returning: filter) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in let reply = self?.pickerReply; self?.pickerReply = nil; reply?.resume(throwing: error) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in guard let self, self.phase != .stopping && self.phase != .idle else { return }; self.onInterruption?(error) }
    }
}
