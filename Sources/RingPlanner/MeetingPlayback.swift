import Foundation
import AVFoundation
import Combine
import RingCore

@MainActor protocol MeetingAudioPlaying: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }
    var onFinish: ((Bool) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}
@MainActor private final class LocalMeetingAudioPlayer: NSObject, MeetingAudioPlaying, AVAudioPlayerDelegate {
    private let audio: AVAudioPlayer
    var onFinish: ((Bool) -> Void)?
    init(url: URL) throws { audio = try AVAudioPlayer(contentsOf: url); super.init(); audio.delegate = self; audio.enableRate = true; audio.prepareToPlay() }
    var currentTime: TimeInterval { get { audio.currentTime } set { audio.currentTime = newValue } }
    var duration: TimeInterval { audio.duration }
    var isPlaying: Bool { audio.isPlaying }
    var rate: Float { get { audio.rate } set { audio.rate = newValue } }
    func play() -> Bool { audio.play() }
    func pause() { audio.pause() }
    func stop() { audio.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.onFinish?(flag) } }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { Task { @MainActor [weak self] in self?.onFinish?(false) } }
}

/// One absolute playhead across the bounded audio files of a long meeting.
@MainActor final class MeetingPlayback: ObservableObject {
    @Published private(set) var recordingID: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    @Published var speed: Float = 1 {
        didSet {
            let value: Float = speed.isFinite ? min(2, max(0.5, speed)) : 1
            if value != speed { speed = value; return }
            player?.rate = value
        }
    }
    private var parts: [MeetingAudioPart] = []
    private var index: Int?
    private var player: MeetingAudioPlaying?
    private var wantsPlayback = false
    private var requestedPosition = 0.0
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    private var clock: Timer?
    private let makePlayer: (URL) throws -> MeetingAudioPlaying
    private let prepare: (URL) async throws -> [MeetingAudioPart]
    private let ticks: Bool
    init(ticks: Bool = true, makePlayer: ((URL) throws -> MeetingAudioPlaying)? = nil, prepare: ((URL) async throws -> [MeetingAudioPart])? = nil) {
        self.ticks = ticks
        self.makePlayer = makePlayer ?? { try LocalMeetingAudioPlayer(url: $0) }
        self.prepare = prepare ?? { folder in
            let task = Task.detached { try MeetingAudioMixer.prepare(folder: folder) }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }
    func load(recordingID id: String, folder: URL, estimatedDuration: Double, at seconds: Double = 0, autoplay: Bool = false) {
        if recordingID == id, preparing || !parts.isEmpty { seek(to: seconds, autoplay: autoplay); return }
        reset(); let token = generation
        recordingID = id; duration = estimatedDuration.isFinite ? max(0, estimatedDuration) : 0
        requestedPosition = seconds.isFinite ? max(0, seconds) : 0
        position = MeetingNavigation.clampedPosition(seconds, duration: duration); wantsPlayback = autoplay; preparing = true
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await prepare(folder)
                try Task.checkCancellation()
                guard generation == token, recordingID == id else { return }
                guard !loaded.isEmpty, loaded.allSatisfy({ $0.offset.isFinite && $0.offset >= 0 && $0.duration.isFinite && $0.duration > 0 }) else { throw MeetingError.validation("No playable audio was found.") }
                parts = loaded.sorted { $0.offset < $1.offset }
                duration = parts.map { $0.offset + $0.duration }.max() ?? 0
                let target = requestedPosition; preparing = false; preparation = nil
                seek(to: target, autoplay: wantsPlayback)
                if ticks {
                    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPosition() } }
                    clock = timer; RunLoop.main.add(timer, forMode: .common)
                }
            } catch {
                guard generation == token else { return }
                preparing = false; preparation = nil; isPlaying = false; wantsPlayback = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func waitUntilPrepared() async { await preparation?.value }
    func seek(to seconds: Double, autoplay: Bool? = nil) {
        if let autoplay { wantsPlayback = autoplay }
        requestedPosition = seconds.isFinite ? max(0, seconds) : 0
        let target = MeetingNavigation.clampedPosition(seconds, duration: duration)
        position = target
        guard !preparing, !parts.isEmpty else { return }
        do {
            let ranges = parts.map { DateInterval(start: Date(timeIntervalSince1970: $0.offset), duration: $0.duration) }
            guard let next = MeetingNavigation.partIndex(at: target, ranges: ranges) else { return }
            if next != index || player == nil {
                player?.stop(); let new = try makePlayer(parts[next].url)
                let token = generation
                new.onFinish = { [weak self, weak new] success in
                    guard let self, let new, self.player === new, self.generation == token else { return }
                    self.finished(successfully: success)
                }
                player = new; index = next; player?.rate = speed
            }
            player?.currentTime = min(player?.duration ?? parts[next].duration, max(0, target - parts[next].offset))
            if wantsPlayback && target < duration {
                guard player?.play() == true else { throw MeetingError.validation("Audio could not start. Check the Mac’s sound output and try again.") }
                isPlaying = true
            } else { player?.pause(); isPlaying = false; if target >= duration { wantsPlayback = false } }
            error = nil
        } catch { self.error = error.localizedDescription; isPlaying = false; wantsPlayback = false }
    }
    func toggle() {
        if isPlaying || wantsPlayback { pause() }
        else { seek(to: position >= duration ? 0 : position, autoplay: true) }
    }
    func pause() { refreshPosition(); wantsPlayback = false; player?.pause(); isPlaying = false }
    func skip(_ seconds: Double) { seek(to: position + seconds) }
    func refreshPosition() {
        guard let player, let index, !preparing else { return }
        position = min(duration, parts[index].offset + min(parts[index].duration, max(0, player.currentTime)))
    }
    private func finished(successfully success: Bool) {
        guard let index else { return }
        guard success else { error = "Playback stopped because an audio part could not be decoded. Your recording is preserved."; isPlaying = false; wantsPlayback = false; return }
        guard wantsPlayback else { return }
        if index + 1 < parts.count { seek(to: parts[index + 1].offset, autoplay: true) }
        else { position = duration; wantsPlayback = false; isPlaying = false }
    }
    func reset() {
        generation = UUID(); preparation?.cancel(); preparation = nil
        clock?.invalidate(); clock = nil; player?.stop(); player = nil; index = nil; parts = []
        recordingID = nil; position = 0; requestedPosition = 0; duration = 0; preparing = false; isPlaying = false; wantsPlayback = false; error = nil
    }
}
