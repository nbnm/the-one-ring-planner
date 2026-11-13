import Foundation
import RingCore

@main enum TelegramAudioChecks {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ring-telegram-audio-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath:$0) }) else { fatalError("Install FFmpeg to verify Telegram Ogg/Opus handling.") }
        let input = base.appendingPathComponent("voice.ogg"), p = Process()
        p.executableURL = URL(fileURLWithPath:ffmpeg); p.arguments = ["-nostdin","-hide_banner","-loglevel","error","-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=365","-c:a","libopus","-b:a","16000",input.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
        let before = try Data(contentsOf:input), parts = try TelegramAudio.prepare(source:input,directory:base.appendingPathComponent("Parts"))
        precondition(parts.count == 3, "365 seconds must make three bounded chunks")
        precondition(parts.allSatisfy { $0.duration > 0 && $0.duration <= 182 && FileManager.default.fileExists(atPath:$0.file.path) })
        precondition(abs(parts.reduce(0) { $0 + $1.duration } - 365) < 1, "No audio may disappear at chunk boundaries")
        precondition(parts[1].offset >= 179 && parts[2].offset >= 359)
        let after = try Data(contentsOf:input)
        precondition(after == before, "Original Opus bytes must remain exact")
        let reused = try TelegramAudio.prepare(source:input,directory:base.appendingPathComponent("Parts"))
        precondition(reused.map(\.file) == parts.map(\.file))
        let broken = base.appendingPathComponent("broken.ogg"); try Data([0,1,2]).write(to:broken)
        var rejected = false
        do { _ = try TelegramAudio.prepare(source:broken,directory:base.appendingPathComponent("Broken")) } catch { rejected = true }
        precondition(rejected)
        let disguised = base.appendingPathComponent("playlist.ogg")
        try Data("#EXTM3U\nhttps://example.invalid/never-fetch\n".utf8).write(to:disguised)
        var refusedPlaylist = false
        do { _ = try TelegramAudio.prepare(source:disguised,directory:base.appendingPathComponent("Playlist")) } catch { refusedPlaylist = true }
        precondition(refusedPlaylist, "Audio conversion must never interpret a forwarded file as a network playlist")
        print("Telegram native audio: 8 checks, 0 failures")
    }
}
