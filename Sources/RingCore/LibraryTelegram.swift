import Foundation

public struct LibraryTelegramFile: Codable, Equatable, Sendable {
    public let hash: String
    public let byteCount: Int
    public let name: String
    public let fileExtension: String
    public init(hash: String, byteCount: Int, name: String, fileExtension: String) { self.hash = hash; self.byteCount = byteCount; self.name = name; self.fileExtension = fileExtension }
}
public struct LibraryTelegramItem: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let capturedAt: Date
    public let files: [LibraryTelegramFile]
    public init(id: String, text: String, capturedAt: Date, files: [LibraryTelegramFile]) { self.id = id; self.text = text; self.capturedAt = capturedAt; self.files = files }
}
public struct LibraryTelegramCapture: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let threadID: String
    public let items: [LibraryTelegramItem]
    public init(id: String, threadID: String, items: [LibraryTelegramItem]) { self.id = id; self.threadID = threadID; self.items = items }
    public func validate() throws {
        guard LibraryHash.isValid(id), LibraryHash.isValid(threadID), !items.isEmpty, items.count <= 30, Set(items.map(\.id)).count == items.count else { throw LibraryError.invalid("The hosted inbox returned an invalid capture group.") }
        for item in items {
            guard !item.id.isEmpty, item.id.count <= 300, item.text.utf8.count <= LibraryPolicy.maximumTextBytes, item.files.count <= 20 else { throw LibraryError.invalid("This hosted capture exceeds the supported limits.") }
            for file in item.files { try LibraryAttachment(hash: file.hash, fileExtension: file.fileExtension, originalName: file.name, byteCount: file.byteCount).validate() }
        }
    }
}
public struct LibraryTelegramClient: Sendable {
    let endpoint: URL
    let token: String
    let http: LibraryHTTP
    public init(endpoint: String, token: String, http: LibraryHTTP = LibraryHTTP()) throws {
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)), !token.isEmpty else { throw LibraryError.invalid("Enter an HTTPS hosted inbox URL and its client token.") }
        self.endpoint = url; self.token = token; self.http = http
    }
    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path)); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); return request
    }
    public func pending() async throws -> [LibraryTelegramCapture] {
        let data = try await http.data(request("v1/captures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let captures = try decoder.decode([LibraryTelegramCapture].self, from: data)
        guard captures.count <= 20 else { throw LibraryError.invalid("The hosted inbox returned too many captures in one page.") }
        for capture in captures { try capture.validate() }; return captures
    }
    public func attachments(_ capture: LibraryTelegramCapture) async throws -> [String: Data] {
        try capture.validate(); var result: [String: Data] = [:]
        for file in capture.items.flatMap(\.files) where result[file.hash] == nil {
            let data = try await http.data(request("v1/captures/\(capture.id)/assets/\(file.hash)"), maximumBytes: LibraryPolicy.maximumAttachmentBytes)
            guard data.count == file.byteCount, LibraryHash.digest(data) == file.hash else { throw LibraryError.invalid("An inbox attachment is incomplete. The hosted capture has not been acknowledged.") }
            result[file.hash] = data
        }; return result
    }
    public func acknowledge(_ capture: LibraryTelegramCapture, noteID: String) async throws {
        guard UUID(uuidString: noteID) != nil else { throw RepositoryError.invalidPath }
        var request = request("v1/captures/\(capture.id)/ack"); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["captureID": capture.id, "noteID": noteID])
        _ = try await http.data(request)
    }
}
public enum LibraryTelegramImporter {
    @discardableResult public static func importCapture(_ capture: LibraryTelegramCapture, bytes: [String: Data], repository: DataRepository) throws -> LibraryNote {
        try capture.validate()
        var prepared: [String: LibraryPreparedAttachment] = [:]
        for file in capture.items.flatMap(\.files) where prepared[file.hash] == nil {
            guard let data = bytes[file.hash], data.count == file.byteCount, LibraryHash.digest(data) == file.hash else { throw LibraryError.invalid("Inbox attachment validation failed. The hosted capture is retained.") }
            prepared[file.hash] = try LibraryAttachments.prepare(data: data, name: file.name, extension: file.fileExtension, localState: repository.localState)
        }
        return try repository.withExclusiveAccess {
            try repository.recoverPendingWrites()
            let receipts = try repository.load(LibraryImportReceipt.self, directory: "note-imports")
            let loaded = try repository.loadLibrary()
            if let receipt = receipts.first(where: { $0.captureID == capture.id }) {
                guard let existing = loaded.notes.first(where: { $0.id == receipt.noteID }) else { throw LibraryError.invalid("A previously imported capture points to a damaged note. Restore the note before acknowledging this capture.") }; return existing
            }
            let threadNoteIDs = Set(receipts.filter { $0.threadID == capture.threadID }.map(\.noteID))
            let current = loaded.notes.filter { threadNoteIDs.contains($0.id) && $0.trashedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }.first
            let known = Set(current?.originals.map(\.id) ?? [])
            let fresh = capture.items.filter { !known.contains($0.id) }
            var note = current ?? LibraryNote(originals: [])
            let expected = current?.revision
            for item in fresh {
                var text = item.text
                for file in item.files where ["md", "markdown", "txt"].contains(file.fileExtension) {
                    if let content = bytes[file.hash].flatMap({ String(data: $0, encoding: .utf8) }) { text += (text.isEmpty ? "" : "\n\n") + content }
                }
                if !text.isEmpty { note.body += (note.body.isEmpty ? "" : "\n\n") + text }
                note.originals.append(LibraryOriginal(id: item.id, text: item.text, attachmentHashes: item.files.map(\.hash), channel: "telegram", capturedAt: item.capturedAt))
                for file in item.files { if let attachment = prepared[file.hash]?.attachment, !note.attachments.contains(where: { $0.hash == attachment.hash }) { note.attachments.append(attachment) } }
            }
            if current != nil && !fresh.isEmpty { note.revision += 1; note.updatedAt = Date() }
            note.unreviewed = true; note.archived = false
            let receipt = LibraryImportReceipt(captureID: capture.id, threadID: capture.threadID, noteID: note.id)
            if fresh.isEmpty, current != nil { try repository.save(libraryReceipts: [receipt], message: "Acknowledge repeated Library album revision"); return note }
            return try repository.saveLibrary(note, expectedRevision: expected, attachments: prepared.values.map(\.write), receipt: receipt, message: "Import private Telegram reference")
        }
    }
}
