import Foundation
import RingCore

@MainActor final class FakeMeetingPlayer: MeetingAudioPlaying {
    var currentTime = 0.0
    let duration: Double
    var isPlaying = false
    var rate: Float = 1
    var onFinish: ((Bool) -> Void)?
    init(duration: Double) { self.duration = duration }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}
@MainActor func checkMeetingPlayback(_ check: (Bool, String) -> Void) async {
    let parts = [MeetingAudioPart(id: "one", url: URL(fileURLWithPath: "/synthetic/one.m4a"), offset: 0, duration: 1200), MeetingAudioPart(id: "two", url: URL(fileURLWithPath: "/synthetic/two.m4a"), offset: 1200, duration: 45)]
    var players: [FakeMeetingPlayer] = []
    var preparations = 0
    let playback = MeetingPlayback(ticks: false, makePlayer: { url in let player = FakeMeetingPlayer(duration: url.lastPathComponent == "one.m4a" ? 1200 : 45); players.append(player); return player }, prepare: { _ in preparations += 1; return parts })
    playback.load(recordingID: "record", folder: URL(fileURLWithPath: "/synthetic"), estimatedDuration: 1245)
    await playback.waitUntilPrepared()
    check(!playback.isPlaying && playback.duration == 1245 && preparations == 1, "Preparing playback does not autoplay or change the total timeline")
    playback.toggle(); players.last!.currentTime = 100; playback.refreshPosition(); playback.pause()
    check(playback.position == 100 && !playback.isPlaying, "Pause retains the absolute playhead")
    playback.toggle(); check(playback.position == 100 && playback.isPlaying && players.count == 1, "Resume uses the same player and position")
    playback.seek(to: 1210)
    check(playback.position == 1210 && players.last!.currentTime == 10 && playback.isPlaying, "Seeking across the 20-minute boundary uses absolute time")
    playback.pause(); playback.seek(to: 1200)
    check(!playback.isPlaying && players.last!.currentTime == 0, "Scrubbing while paused stays paused at an exact part boundary")
    playback.speed = 1.5; playback.toggle()
    check(players.last!.rate == 1.5 && playback.isPlaying, "Playback rate persists across audio parts")
    playback.seek(to: 1190, autoplay: true); let first = players.last!
    first.currentTime = 1200; first.onFinish?(true)
    check(playback.isPlaying && playback.position == 1200 && players.last!.rate == 1.5, "Finishing one audio file continues automatically into the next")
    first.onFinish?(true)
    check(playback.position == 1200, "A late completion from an old player cannot advance the new one")
    players.last!.currentTime = 45; players.last!.onFinish?(true)
    check(!playback.isPlaying && playback.position == 1245, "The final part ends at the total recording duration")
    playback.toggle(); check(playback.isPlaying && playback.position == 0, "Play after reaching the end replays from the beginning")
    playback.speed = .nan; check(playback.speed == 1, "Invalid playback speeds normalize without recursive property updates")
    playback.pause(); playback.load(recordingID: "record", folder: URL(fileURLWithPath: "/synthetic"), estimatedDuration: 1245, at: 40, autoplay: true)
    check(preparations == 1 && playback.position == 40, "Timestamp jumps reuse prepared audio without re-mixing")
    playback.reset(); check(playback.recordingID == nil && playback.position == 0 && !playback.isPlaying, "Changing recordings clears the old playhead and playback state")
    let late = MeetingPlayback(ticks: false, makePlayer: { _ in FakeMeetingPlayer(duration: 1200) }, prepare: { url in
        if url.lastPathComponent == "old" { try? await Task.sleep(for: .milliseconds(60)) }
        return [parts[0]]
    })
    late.load(recordingID: "old", folder: URL(fileURLWithPath: "/old"), estimatedDuration: 0)
    await Task.yield()
    late.load(recordingID: "new", folder: URL(fileURLWithPath: "/new"), estimatedDuration: 0, at: 30)
    await late.waitUntilPrepared()
    try? await Task.sleep(for: .milliseconds(90))
    check(late.recordingID == "new" && late.position == 30 && !late.isPlaying, "Late preparation cannot replace a new selection or lose a requested seek")
    late.reset()
}
