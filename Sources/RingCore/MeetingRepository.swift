import Foundation

/// Audio, transcripts and speaker names deliberately stay outside the planner's Git repository.
public final class MeetingRepository: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func folder(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains("..") else { throw MeetingError.storage }
        let url = root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: url.path), (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw MeetingError.storage }
        return url
    }
    public func save(_ meeting: MeetingRecording) throws {
        let directory = try folder(meeting.id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent("meeting.json")
        try encoder.encode(meeting).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load() throws -> [MeetingRecording] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return try entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { entry in
            let directory = try folder(entry.lastPathComponent), file = directory.appendingPathComponent("meeting.json")
            guard fm.fileExists(atPath: file.path) else { return nil }
            var meeting = try decoder.decode(MeetingRecording.self, from: Data(contentsOf: file))
            guard meeting.id == entry.lastPathComponent else { throw MeetingError.storage }
            if meeting.state == .recording || meeting.isProcessing {
                meeting.state = .interrupted
                meeting.lastError = "This session was interrupted. Saved audio and completed processing are available below."
                try save(meeting)
            }
            if let draft = meeting.retranscription, draft.content.state == .transcribing || draft.content.state == .analyzing {
                meeting.retranscription?.content.state = .interrupted
                meeting.retranscription?.content.lastError = "This transcription was interrupted. Resume to keep completed chunks."
                try save(meeting)
            }
            return meeting
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
