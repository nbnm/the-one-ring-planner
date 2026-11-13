import Foundation

public enum InboxKind: String, Codable, CaseIterable, Sendable { case task = "Task", note = "Note", unknown = "Unsorted" }
public struct InboxClassification: Codable, Equatable, Sendable {
    public let kind: InboxKind
    public let title: String
    public let tags: [String]
    public init(kind: InboxKind, title: String, tags: [String]) { self.kind = kind; self.title = title; self.tags = TaskTags.normalize(tags.map(CaptureVocabulary.normalize)) }
}
public struct InboxRoute: Codable, Equatable, Sendable {
    public let kind: InboxKind
    public let recordID: String
    public init(kind: InboxKind, recordID: String) { self.kind = kind; self.recordID = recordID }
}
/// A capture is neither a planner task nor a Library note until the owner places it.
public struct InboxItem: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public let id: String
    public let text: String
    public let sourceURL: String
    public let attachments: [LibraryAttachment]
    public let createdAt: Date
    public var revision = 1
    public var telegramSourceID: String?
    public var telegramAudio: Bool?
    public var transcript: String?
    public var content: String { transcript ?? text }
    public var awaitingTranscription: Bool { telegramSourceID != nil && transcript == nil && (telegramAudio == true || attachments.contains { ["ogg", "oga", "opus", "mp3", "m4a", "wav", "aac", "flac"].contains($0.fileExtension) }) }
    public var classification: InboxClassification?
    public var titleOverride: String?
    public var tagsOverride: [String]?
    public var route: InboxRoute?
    public var archived = false
    public init(id: String = UUID().uuidString.lowercased(), text: String, sourceURL: String = "", attachments: [LibraryAttachment] = [], now: Date = Date()) {
        self.id = id; self.text = text; self.attachments = attachments
        self.sourceURL = sourceURL.isEmpty ? ReferenceLinks.extract(text).first?.absoluteString ?? "" : sourceURL
        createdAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    }
    public var title: String { titleOverride ?? classification?.title ?? content.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? attachments.first?.originalName ?? "Saved item" }
    public var tags: [String] { tagsOverride ?? classification?.tags ?? [] }
    public var suggestedKind: InboxKind { classification?.kind ?? .unknown }
    public var active: Bool { route == nil && !archived }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: id) != nil, revision > 0, text.utf8.count <= LibraryPolicy.maximumTextBytes, attachments.count <= 100, Set(attachments.map(\.hash)).count == attachments.count,
              title.count <= 512, tags.count <= 24, tags.allSatisfy({ $0.count <= 128 }), sourceURL.count <= 4096 else { throw LibraryError.invalid("This Inbox item exceeds the supported limits. Its source is preserved.") }
        if !sourceURL.isEmpty { guard ReferenceLinks.valid(sourceURL) != nil else { throw LibraryError.invalid("Use an HTTP or HTTPS link without credentials.") } }
        if let route { guard route.kind != .unknown, UUID(uuidString: route.recordID) != nil else { throw LibraryError.invalid("Invalid Inbox destination.") } }
        guard (transcript?.utf8.count ?? 0) <= LibraryPolicy.maximumTextBytes, (telegramSourceID?.count ?? 0) <= 100 else { throw LibraryError.invalid("Invalid Telegram transcript metadata.") }
        for a in attachments { try a.validate() }
    }
    public func task(settings: PlanningSettings) -> PlannerTask {
        var task = PlannerTask(id: id, title: String(title.prefix(160)), notes: content, tags: tags, now: createdAt)
        task.attachments = attachments; task.minimumBlockMinutes = settings.minimumFocusMinutes
        return task
    }
    public func note() -> LibraryNote {
        var note = LibraryNote(id: id, title: title, body: content, sourceURL: sourceURL, attachments: attachments,
                               originals: [LibraryOriginal(id: id, text: text, sourceURL: sourceURL, attachmentHashes: attachments.map(\.hash), channel: "inbox", capturedAt: createdAt)], now: createdAt)
        note.tags = tags; if !tags.isEmpty { note.userFields.insert("tags") }; return note
    }
}
public enum ReferenceLinks {
    public static func valid(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, text.count <= 4096 else { return nil }; return url
    }
    public static func extract(_ text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let raw = match.url?.absoluteString, let url = valid(raw), seen.insert(raw).inserted else { return nil }; return url
        }
    }
}
public struct InboxJob: Codable, Identifiable, Sendable {
    public let itemID: String
    public let revision: Int
    public var attempts = 0
    public var nextAttempt: Date?
    public var lastError: String?
    public var id: String { itemID + "-" + String(revision) }
    public init(_ item: InboxItem) { itemID = item.id; revision = item.revision }
}
