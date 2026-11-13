import Foundation

public struct TelegramPollingSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var botID: Int64?
    public var username = ""
    public var interval = 15
    public var audioModel = ""
    public var splitAudio = true
    public var dailyDigest = false
    public var digestMinute = 540
    public var eventAlerts = false
    public var urgentAlerts = false
    public init() {}
    public var isValid: Bool { (5...300).contains(interval) && (0..<1440).contains(digestMinute) && (!eventAlerts || interval <= 30) && audioModel.count <= 200 }
}
public struct TelegramInboundJob: Codable, Identifiable, Sendable {
    public var id: Int64 { update.update_id }
    public var update: TelegramUpdate
    public var attempts = 0
    public var nextAttempt: Date?
    public var lastError: String?
    public var chunkText: [String: String] = [:]
    public var audioConfiguration: String?
    public var transcript: String?
    public var drafts: [TelegramDraft]?
    public init(_ update: TelegramUpdate) { self.update = update }
}
public struct TelegramDraft: Codable, Sendable {
    public var title: String
    public var notes: String
    public var tags: [String]
    public init(_ draft: CaptureDraft) { title = draft.title; notes = draft.notes; tags = draft.tags }
}
public struct TelegramOutgoing: Codable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var expiresAt: Date
    public var notBefore: Date?
    public var attemptedAt: Date?
    public var lastError: String?
    public init(id: String, text: String, expiresAt: Date = Date().addingTimeInterval(3600)) { self.id = id; self.text = text; self.expiresAt = expiresAt }
}
public struct TelegramPollingState: Codable, Sendable {
    public var offset: Int64 = 0
    public var ownerID: Int64?
    public var jobs: [TelegramInboundJob] = []
    public var outbox: [TelegramOutgoing] = []
    public var delivered: [String: Date] = [:]
    public init() {}
    /// Called before the next getUpdates request: offset acknowledgement follows local durability.
    public mutating func receive(_ updates: [TelegramUpdate]) throws {
        var next = self
        for update in updates.sorted(by: { $0.update_id < $1.update_id }) where update.update_id >= next.offset {
            guard update.update_id >= 0, update.update_id < Int64.max else { throw TelegramBotError.invalidResponse }
            if let ownerID = next.ownerID, let message = update.message, message.belongs(to: ownerID), !next.jobs.contains(where: { $0.id == update.update_id }) {
                guard next.jobs.count < 1000 else { throw TelegramBotError.configuration("Telegram queue is full. Retry pending captures before downloading more messages.") }
                next.jobs.append(TelegramInboundJob(update))
            }
            next.offset = max(next.offset, update.update_id + 1)
        }
        self = next
    }

    public mutating func queue(id: String, text: String, expiresAt: Date = Date().addingTimeInterval(3600)) {
        guard delivered[id] == nil, !outbox.contains(where: { $0.id == id }) else { return }
        outbox.append(TelegramOutgoing(id: id, text: text, expiresAt: expiresAt))
    }
    public mutating func prune(now: Date) {
        delivered = delivered.filter { $0.key.hasPrefix("urgent:") || now.timeIntervalSince($0.value) < 7 * 86400 }
        outbox.removeAll { $0.expiresAt < now }
    }
}
public enum TelegramCapture {
    public static func identity(botID: Int64, updateID: Int64, part: Int = 0) -> String {
        let raw = Array(LibraryHash.digest(Data("telegram:\(botID):\(updateID):\(part)".utf8)).prefix(32))
        return [String(raw[0..<8]), String(raw[8..<12]), String(raw[12..<16]), String(raw[16..<20]), String(raw[20..<32])].joined(separator: "-")
    }
    public static func save(_ update: TelegramUpdate, botID: Int64, ownerID: Int64, attachment: LibraryPreparedAttachment?, repository: DataRepository) throws -> InboxItem {
        guard let message = update.message, message.belongs(to: ownerID) else { throw TelegramBotError.configuration("Only the paired owner's private messages can enter Inbox.") }
        return try repository.withExclusiveAccess {
            try repository.recoverPendingWrites()
            let id = identity(botID: botID, updateID: update.update_id)
            if var existing = try repository.loadInbox().first(where: { $0.id == id }) {
                if let attachment, existing.attachments.isEmpty, existing.telegramSourceID == "\(botID):\(update.update_id)" {
                    var restored = InboxItem(id: existing.id, text: existing.text, sourceURL: existing.sourceURL, attachments: [attachment.attachment], now: existing.createdAt)
                    restored.revision = existing.revision + 1; restored.titleOverride = existing.titleOverride; restored.tagsOverride = existing.tagsOverride
                    restored.route = existing.route; restored.archived = existing.archived; restored.telegramSourceID = existing.telegramSourceID
                    restored.telegramAudio = existing.telegramAudio; restored.transcript = existing.transcript
                    if existing.titleOverride != nil || existing.tagsOverride != nil { restored.classification = existing.classification }
                    try repository.save(inboxItems: [restored], attachments: [attachment.write], message: "Recover Telegram source attachment")
                    existing = restored
                }
                return existing
            }
            var item = InboxItem(id: id, text: message.content, attachments: attachment.map { [$0.attachment] } ?? [], now: Date(timeIntervalSince1970: TimeInterval(message.date)))
            item.telegramSourceID = "\(botID):\(update.update_id)"
            item.telegramAudio = message.isAudio
            return try repository.saveInbox(item, expectedRevision: nil, attachments: attachment.map { [$0.write] } ?? [])
        }
    }
    /// Original caption/audio stay immutable; the transcript is derived content. Split suggestions stay in Inbox, never the matrix.
    public static func finishAudio(update: TelegramUpdate, botID: Int64, transcript: String, drafts: [TelegramDraft], repository: DataRepository) throws -> [InboxItem] {
        guard !transcript.isEmpty, transcript.utf8.count <= LibraryPolicy.maximumTextBytes, drafts.count <= 12 else { throw TelegramBotError.configuration("The transcript exceeds the supported capture size. Original audio is preserved.") }
        return try repository.withExclusiveAccess {
            try repository.recoverPendingWrites()
            let id = identity(botID: botID, updateID: update.update_id)
            guard var original = try repository.loadInbox().first(where: { $0.id == id }), original.telegramSourceID == "\(botID):\(update.update_id)" else { throw LibraryError.stale }
            let canSplit = drafts.count > 1 && original.route == nil && !original.archived && original.titleOverride == nil && original.tagsOverride == nil
            original.transcript = transcript; original.revision += 1
            if canSplit {
                var results: [InboxItem] = []
                for (index, draft) in drafts.enumerated() {
                    var item = InboxItem(id: identity(botID: botID, updateID: update.update_id, part: index + 1), text: [draft.title, draft.notes].filter { !$0.isEmpty }.joined(separator: "\n\n"), attachments: original.attachments, now: original.createdAt)
                    item.telegramSourceID = original.telegramSourceID
                    item.classification = InboxClassification(kind: .task, title: draft.title, tags: draft.tags)
                    results.append(item)
                }
                original.archived = true
                // Repeated recovery never resurrects or replaces a child the owner already edited or moved.
                let existing = Set(try repository.loadInbox().map(\.id))
                let fresh = results.filter { !existing.contains($0.id) }
                try repository.save(inboxItems: [original] + fresh, message: "Transcribe Telegram audio and split Inbox suggestions")
                return [original] + fresh
            }
            if original.classification == nil, let draft = drafts.first { original.classification = InboxClassification(kind: .task, title: draft.title, tags: draft.tags) }
            try repository.save(inboxItems: [original], message: "Save Telegram voice transcript")
            return [original]
        }
    }
}

public enum TelegramPairing {
    public static func matches(_ message: TelegramMessage, code: String?, expires: Date?, now: Date) -> Bool {
        guard let code, code.count == 32, let expires, expires > now,
              message.chat.type == "private", message.chat.id == message.from?.id, message.from?.is_bot != true,
              let text = message.text else { return false }
        let parts = text.split(whereSeparator: \.isWhitespace)
        return parts.count == 2 && parts[0].split(separator: "@").first == "/pair" && parts[1] == code
    }
}
