import Foundation

public struct RepositoryAttachmentWrite: Codable, Equatable, Sendable {
    public let path: String
    public let stagedPath: String
    public let hash: String
    public let byteCount: Int
    public init(path: String, stagedPath: String, hash: String, byteCount: Int) { self.path = path; self.stagedPath = stagedPath; self.hash = hash; self.byteCount = byteCount }
    public func install(root: URL, localState: URL) throws {
        let pieces = stagedPath.split(separator: "/"), ext = URL(fileURLWithPath: path).pathExtension
        guard LibraryHash.isValid(hash), path == "note-assets/\(hash).\(ext)", LibraryPolicy.attachmentExtensions.contains(ext), path.split(separator: "/").count == 2,
              !path.contains(".."), pieces.count == 3, pieces[0] == "library-staging", UUID(uuidString: String(pieces[1])) != nil,
              !stagedPath.contains(".."), !stagedPath.contains("\\"), !stagedPath.hasPrefix("/"), byteCount > 0, byteCount <= LibraryPolicy.maximumAttachmentBytes else { throw RepositoryError.invalidPath }
        let target = root.appendingPathComponent(path), staged = localState.appendingPathComponent(stagedPath)
        for base in [root.appendingPathComponent("note-assets"), target, localState.appendingPathComponent("library-staging"), staged.deletingLastPathComponent(), staged] {
            if FileManager.default.fileExists(atPath: base.path), (try base.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw RepositoryError.invalidPath }
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: target)
            guard data.count == byteCount, LibraryHash.digest(data) == hash else { throw LibraryError.invalid("An attachment failed its hash check. Original files are preserved.") }; return
        }
        let data = try Data(contentsOf: staged)
        guard data.count == byteCount, LibraryHash.digest(data) == hash else { throw LibraryError.invalid("Staged attachment bytes are incomplete. Keep the draft and retry the import.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
public struct LibraryPreparedAttachment: Sendable { public let attachment: LibraryAttachment; public let write: RepositoryAttachmentWrite }
public enum LibraryAttachments {
    public static func prepare(data: Data, name: String, extension ext: String, localState: URL) throws -> LibraryPreparedAttachment {
        let hash = LibraryHash.digest(data), attachment = LibraryAttachment(hash: hash, fileExtension: ext, originalName: String(name.prefix(512)), byteCount: data.count)
        try attachment.validate()
        let path = "library-staging/\(UUID().uuidString.lowercased())/\(hash).\(ext.lowercased())"
        let file = localState.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return LibraryPreparedAttachment(attachment: attachment, write: RepositoryAttachmentWrite(path: attachment.path, stagedPath: path, hash: hash, byteCount: data.count))
    }
}
extension DataRepository {
    public func loadLibrary() throws -> LibraryLoad {
        try withExclusiveAccess {
            let directory = root.appendingPathComponent("notes")
            guard FileManager.default.fileExists(atPath: directory.path) else { return LibraryLoad(notes: [], failures: []) }
            var notes: [LibraryNote] = [], failures: [String] = []
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            _ = try validatedURL("notes/00000000-0000-0000-0000-000000000000.json")
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw LibraryError.unavailable("Cannot read Library folders.") }
            var seen = Set<String>()
            for case let file as URL in files {
                let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let relative = fileParts.dropFirst(rootParts.count).joined(separator: "/")
                if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants(); failures.append(relative); continue }
                guard file.pathExtension == "json" else { continue }
                do {
                    _ = try validatedURL(relative)
                    guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 24 * 1024 * 1024 else { throw LibraryError.invalid("Oversized note record") }
                    let note = try decoder.decode(LibraryNote.self, from: Data(contentsOf: file)); try note.validate()
                    guard relative == note.recordPath, seen.insert(note.id).inserted else { throw RepositoryError.invalidPath }
                    notes.append(note)
                } catch { failures.append(file.lastPathComponent) }
            }
            return LibraryLoad(notes: notes.sorted { $0.updatedAt > $1.updatedAt }, failures: failures.sorted())
        }
    }
    @discardableResult public func saveLibrary(_ note: LibraryNote, expectedRevision: Int?, attachments: [RepositoryAttachmentWrite] = [], receipt: LibraryImportReceipt? = nil, message: String = "Save Library note") throws -> LibraryNote {
        try withExclusiveAccess {
            let note = note.canonicalized()
            // Recover first, including a prior save whose Git commit failed.
            try recoverPendingWrites()
            let current = try loadLibrary().notes.first { $0.id == note.id }
            if current == note { if let receipt { try save(libraryReceipts: [receipt], message: message) }; return note }
            guard current?.revision == expectedRevision else { throw LibraryError.stale }
            try note.validate()
            let newPaths = Set(attachments.map(\.path))
            for a in note.attachments {
                let url = try validatedURL(a.path)
                if !newPaths.contains(a.path) {
                    guard let bytes = try? Data(contentsOf: url), LibraryHash.digest(bytes) == a.hash, bytes.count == a.byteCount else { throw LibraryError.invalid("An original attachment is missing or corrupt. Restore it before editing this note.") }
                }
            }
            let existingBytes = try assetByteCount()
            let extra = attachments.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }.reduce(0) { $0 + $1.byteCount }
            guard existingBytes + extra <= LibraryPolicy.maximumAssetBytes else { throw LibraryError.invalid("The 256 MB small-library attachment limit is reached. Export an archive before adding more images.") }
            try save(notes: [note], libraryReceipts: receipt.map { [$0] } ?? [], attachments: attachments, message: message)
            return note
        }
    }
    public func assetByteCount() throws -> Int {
        let folder = root.appendingPathComponent("note-assets")
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) { total, url in
            _ = try validatedURL("note-assets/\(url.lastPathComponent)"); return total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
}
