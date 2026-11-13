import Foundation
import AVFoundation
import RingCore

enum TelegramAudio {
    struct Part: Sendable { let id: String; let file: URL; let offset: Double; let duration: Double }
    static func prepare(source: URL, directory: URL) throws -> [Part] {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TelegramBotError.configuration("Voice processing needs FFmpeg. Install it with brew install ffmpeg, then retry this capture. Original audio is saved.")
        }
        let formats = ["ogg":"ogg", "oga":"ogg", "opus":"ogg", "mp3":"mp3", "m4a":"mov", "mp4":"mov", "mov":"mov", "wav":"wav", "aac":"aac", "flac":"flac", "webm":"matroska"]
        guard let format = formats[source.pathExtension.lowercased()] else { throw TelegramBotError.configuration("Use Ogg/Opus, MP3, M4A, WAV, AAC, FLAC or WebM audio. The original file is preserved.") }
        let marker = directory.appendingPathComponent("ready.json")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let process = Process(); process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe", "-f", format, "-i", source.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-t", "7201", "-c:a", "aac", "-b:a", "32000", "-f", "segment", "-segment_time", "180", "-segment_format", "mp4", "-reset_timestamps", "1", directory.appendingPathComponent("part-%04d.m4a").path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); let deadline = Date().addingTimeInterval(180)
            while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); process.waitUntilExit(); try Task.checkCancellation(); throw TelegramBotError.configuration("Audio conversion timed out. Original audio is saved; retry or send shorter clips.") }
            guard process.terminationStatus == 0 else { throw TelegramBotError.configuration("This audio format could not be decoded. Original audio is saved; retry or send an MP3/M4A file.") }
            let parts = try parts(in: directory)
            guard !parts.isEmpty, parts.reduce(0, { $0 + $1.duration }) <= 7200.5 else { throw TelegramBotError.configuration("Use audio recordings of up to two hours. Original audio is saved.") }
            try Data("true".utf8).write(to: marker, options: .atomic)
            return parts
        }
        return try parts(in: directory)
    }
    private static func parts(in directory: URL) throws -> [Part] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("part-") && $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty, files.count <= 41 else { throw TelegramBotError.configuration("The audio could not be split into supported chunks. Original audio is saved.") }
        var offset = 0.0
        return try files.map { file in
            let audio = try AVAudioFile(forReading: file), duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0, duration <= 182 else { throw TelegramBotError.configuration("An audio chunk is invalid. Original audio is saved.") }
            defer { offset += duration }
            return Part(id: file.deletingPathExtension().lastPathComponent, file: file, offset: offset, duration: duration)
        }
    }
}
