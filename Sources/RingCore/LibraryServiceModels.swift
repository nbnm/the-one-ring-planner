import Foundation

public struct LibraryAutomationSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowImages = false
    public var textModel = ""
    public var visionModel = ""
    public var embeddingModel = ""
    public var monthlyRequests = 200
    public init() {}
}
public struct LibraryCapabilities: Codable, Equatable, Sendable {
    public var visionConfiguration: String?
    public var embeddingConfiguration: String?
    public var embeddingDimensions: Int?
    public init() {}
    public static func key(baseURL: String, model: String) -> String { LibraryHash.digest(Data((baseURL + "|" + model).utf8)) }
}
public struct LibraryJob: Codable, Identifiable, Sendable {
    public var id: String { noteID + "-" + String(revision) }
    public let noteID: String
    public let revision: Int
    public var ocrDone = false
    public var organizationDone = false
    public var embeddingDone = false
    public var attempts = 0
    public var nextAttempt: Date?
    public var lastError: String?
    public init(noteID: String, revision: Int) { self.noteID = noteID; self.revision = revision }
}
public struct LibraryRequestLedger: Codable, Sendable {
    public var month = ""
    public var requests = 0
    public init() {}
    public mutating func consume(limit: Int, now: Date = Date()) throws {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM"
        let key = f.string(from: now)
        if month != key { month = key; requests = 0 }
        guard limit > 0, requests < limit else { throw LibraryError.budget }; requests += 1
    }
}
public struct LibraryBackupSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var remoteURL = ""
    public var authentication: BackupAuthentication? = nil
    public var verifiedPrivateRemote: String?
    public init() {}
}
public struct LibraryBackupState: Codable, Sendable {
    public var localCommit: String?
    public var verifiedCommit: String?
    public var lastSuccess: Date?
    public var lastError: String?
    public var nextAttempt: Date?
    public init() {}
}
public struct LibraryTelegramSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var endpoint = ""
    public init() {}
}
public struct LibraryRestorePreview: Identifiable, Sendable {
    public let id: String
    public let workspace: URL
    public let noteCount: Int
    public let taskCount: Int
    public let inboxCount: Int
    public let includesMeetings: Bool
    public init(workspace: URL, noteCount: Int, taskCount: Int, inboxCount: Int = 0, includesMeetings: Bool) {
        id = UUID().uuidString; self.workspace = workspace; self.noteCount = noteCount; self.taskCount = taskCount; self.inboxCount = inboxCount; self.includesMeetings = includesMeetings
    }
}
