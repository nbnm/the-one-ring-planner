import Foundation
import CryptoKit

public enum LibraryError: LocalizedError {
    case invalid(String), stale, unavailable(String), network(Int), budget
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .unavailable(let text): return text
        case .stale: return "This note changed. Reopen its latest version before saving. Your draft is preserved."
        case .network(let code): return "Library service returned HTTP \(code). Your saved notes are safe. Check settings or retry."
        case .budget: return "The Library monthly request budget is used up. Local saving and keyword search remain available."
        }
    }
}
public enum CaptureDestination: String, CaseIterable, Codable, Sendable { case inbox = "Inbox", task = "Task", note = "Note" }
public enum LibraryKind: String, CaseIterable, Codable, Sendable { case general = "General", prompt = "Prompt", skill = "Skill", design = "Design", photograph = "Photograph", technique = "Technique" }
public struct LibraryAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let fileExtension: String
    public let originalName: String
    public let byteCount: Int
    public var path: String { "note-assets/\(hash).\(fileExtension)" }
    public var isImage: Bool { ["png", "jpg", "jpeg", "heic"].contains(fileExtension) }
    public init(hash: String, fileExtension: String, originalName: String, byteCount: Int) {
        self.hash = hash; self.fileExtension = fileExtension.lowercased(); self.originalName = originalName; self.byteCount = byteCount
    }
    public func validate() throws {
        guard LibraryHash.isValid(hash), LibraryPolicy.attachmentExtensions.contains(fileExtension),
              byteCount > 0, byteCount <= LibraryPolicy.maximumAttachmentBytes, originalName.count <= 512 else {
            throw LibraryError.invalid("Unsupported or oversized attachment. Keep each file under 20 MB.")
        }
    }
}
public enum LibraryPolicy {
    public static let attachmentExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "md", "markdown", "txt", "pdf", "docx", "xlsx", "pptx", "csv", "json", "zip", "ogg", "oga", "opus", "mp3", "m4a", "wav", "aac", "flac", "mp4", "mov", "webm", "webp", "tgs", "vcf", "bin"]
    public static let maximumAttachmentBytes = 20 * 1024 * 1024
    public static let maximumAssetBytes = 256 * 1024 * 1024
    public static let maximumTextBytes = 2 * 1024 * 1024
}
public enum LibraryHash {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func isValid(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}
public struct LibraryOriginal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let prompt: String
    public let comments: String
    public let sourceURL: String
    public let attachmentHashes: [String]
    public let channel: String
    public let capturedAt: Date
    public init(id: String = UUID().uuidString.lowercased(), text: String, prompt: String = "", comments: String = "", sourceURL: String = "", attachmentHashes: [String] = [], channel: String = "mac", capturedAt: Date = Date()) {
        self.id = id; self.text = text; self.prompt = prompt; self.comments = comments; self.sourceURL = sourceURL
        self.attachmentHashes = attachmentHashes; self.channel = channel; self.capturedAt = Date(timeIntervalSince1970: floor(capturedAt.timeIntervalSince1970))
    }
}
public struct LibraryEnrichment: Codable, Equatable, Sendable {
    public var inputRevision: Int
    public var title: String
    public var summary: String
    public var tags: [String]
    public var kinds: [LibraryKind]
    public var imageDescriptions: [String: String]
    public var relatedNoteIDs: [String]
    public var model: String
    public var generatedAt: Date
    public var partial: Bool
    public init(inputRevision: Int, title: String, summary: String, tags: [String], kinds: [LibraryKind], imageDescriptions: [String: String] = [:], relatedNoteIDs: [String] = [], model: String, generatedAt: Date = Date(), partial: Bool = false) {
        self.inputRevision = inputRevision; self.title = title; self.summary = summary; self.tags = tags; self.kinds = kinds
        self.imageDescriptions = imageDescriptions; self.relatedNoteIDs = relatedNoteIDs; self.model = model; self.generatedAt = Date(timeIntervalSince1970: floor(generatedAt.timeIntervalSince1970)); self.partial = partial
    }
}
public struct LibraryNote: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var revision: Int = 1
    public var title: String
    public var body: String
    public var prompt: String
    public var comments: String
    public var sourceURL: String
    public var folder: String? = nil
    public var tags: [String] = []
    public var kinds: [LibraryKind] = []
    public var attachments: [LibraryAttachment]
    public var originals: [LibraryOriginal]
    public var createdAt: Date
    public var updatedAt: Date
    public var favorite = false
    public var unreviewed = true
    public var archived = false
    public var trashedAt: Date?
    public var automationAllowed = true
    public var userFields: Set<String> = []
    public var enrichment: LibraryEnrichment?
    public init(id: String = UUID().uuidString.lowercased(), title: String = "", body: String = "", prompt: String = "", comments: String = "", sourceURL: String = "", attachments: [LibraryAttachment] = [], originals: [LibraryOriginal]? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.prompt = prompt; self.comments = comments; self.sourceURL = sourceURL; self.attachments = attachments
        self.originals = originals ?? [LibraryOriginal(text: body, prompt: prompt, comments: comments, sourceURL: sourceURL, attachmentHashes: attachments.map(\.hash), capturedAt: now)]
        self.createdAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)); self.updatedAt = self.createdAt
        if !title.isEmpty { userFields.insert("title") }
    }
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !userFields.contains("title"), let title = enrichment?.title, !title.isEmpty { return title }
        return body.split(whereSeparator: \.isNewline).first.map { String($0.prefix(90)) } ?? (attachments.isEmpty ? "Untitled note" : "Image or file reference")
    }
    public var displayTags: [String] { userFields.contains("tags") || !tags.isEmpty ? tags : enrichment?.tags ?? [] }
    public var displayKinds: [LibraryKind] { userFields.contains("kinds") || !kinds.isEmpty ? kinds : enrichment?.kinds ?? [] }
    public var reusableText: String { prompt.isEmpty ? body : prompt }
    public func canonicalized() -> LibraryNote {
        var value = self
        value.createdAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        value.updatedAt = Date(timeIntervalSince1970: floor(updatedAt.timeIntervalSince1970))
        value.trashedAt = trashedAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        return value
    }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: id) != nil, revision > 0, title.count <= 512,
              [body, prompt, comments].allSatisfy({ $0.utf8.count <= LibraryPolicy.maximumTextBytes }), originals.count <= 2000,
              attachments.count <= 100, Set(attachments.map(\.hash)).count == attachments.count, tags.count <= 24, tags.allSatisfy({ $0.count <= 128 }), sourceURL.count <= 4096,
              originals.reduce(0, { $0 + $1.text.utf8.count + $1.prompt.utf8.count + $1.comments.utf8.count }) <= 12 * 1024 * 1024 else {
            throw LibraryError.invalid("This note is invalid or exceeds the Library size limit. Its source is preserved.")
        }
        if let folder { try LibraryFolders.validate(folder) }
        for a in attachments { try a.validate() }
        if !sourceURL.isEmpty { guard let u = URL(string: sourceURL), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil, u.user == nil, u.password == nil else { throw LibraryError.invalid("Use an HTTP or HTTPS source URL without credentials.") } }
    }
    public func applying(_ result: LibraryEnrichment) throws -> LibraryNote {
        guard result.inputRevision == revision, automationAllowed, trashedAt == nil else { throw LibraryError.stale }
        var copy = self; copy.enrichment = result; return copy
    }
}
public struct LibraryDraft: Codable, Equatable, Sendable {
    public var createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    public var id = UUID().uuidString.lowercased()
    public var title = ""
    public var body = ""
    public var prompt = ""
    public var comments = ""
    public var sourceURL = ""
    public var files: [URL] = []
    public init() {}
    public var hasContent: Bool { !body.isEmpty || !prompt.isEmpty || !comments.isEmpty || !sourceURL.isEmpty || !files.isEmpty }
}
public struct LibraryImportReceipt: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public let captureID: String
    public let threadID: String
    public let noteID: String
    public let importedAt: Date
    public init(captureID: String, threadID: String, noteID: String, now: Date = Date()) {
        self.id = LibraryHash.digest(Data(captureID.utf8)); self.captureID = captureID; self.threadID = threadID; self.noteID = noteID; self.importedAt = now
    }
}
public struct LibraryLoad: Sendable { public var notes: [LibraryNote]; public var failures: [String] }
