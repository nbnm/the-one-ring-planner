import Foundation

/// User-visible folder paths map directly to directories below Data/notes.
public enum LibraryFolders {
    public static func validate(_ path: String) throws {
        guard !path.isEmpty, path.count <= 240, path == path.precomposedStringWithCanonicalMapping,
              !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains(".."), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw LibraryError.invalid("Use a folder name or a path such as Home/Ideas, without dots, colons or backslashes.") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 8, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.count <= 80 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else { throw LibraryError.invalid("Use up to eight folder levels with short, nonempty names.") }
    }
    public static func expanded(_ paths: [String]) throws -> [String] {
        var result = Set<String>()
        for path in paths { try validate(path); let pieces = path.split(separator: "/"); for n in 1...pieces.count { result.insert(pieces.prefix(n).joined(separator: "/")) } }
        guard Set(result.map { $0.lowercased() }).count == result.count else { throw LibraryError.invalid("A folder with the same name and different capitalization already exists.") }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public static func contains(_ folder: String?, note: LibraryNote) -> Bool {
        guard let folder else { return true }
        let path = note.folder ?? ""
        return folder.isEmpty ? path.isEmpty : path == folder || path.hasPrefix(folder + "/")
    }
}
extension LibraryNote {
    public var recordPath: String { "notes/" + (folder.map { $0 + "/" } ?? "") + id + ".json" }
}
extension DataRepository {
    public func libraryFolders() throws -> [String] {
        try withExclusiveAccess {
            let url = try validatedURL("settings/library-folders.json")
            let saved = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode([String].self, from: Data(contentsOf: url)) : []
            return try LibraryFolders.expanded(saved + loadLibrary().notes.compactMap(\.folder))
        }
    }
    public func createLibraryFolder(_ path: String) throws {
        try withExclusiveAccess {
            let folders = try LibraryFolders.expanded(libraryFolders() + [path])
            try save(libraryFolders: folders, message: "Create Library folder")
        }
    }
    public func renameLibraryFolder(_ old: String, to new: String) throws {
        try withExclusiveAccess {
            try LibraryFolders.validate(old); try LibraryFolders.validate(new)
            guard old != new, !new.hasPrefix(old + "/") else { throw LibraryError.invalid("Choose a different folder outside the current folder.") }
            let existing = try libraryFolders()
            guard existing.contains(old), !existing.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) else { throw LibraryError.invalid("That folder is missing or the destination already exists.") }
            func moved(_ path: String) -> String { path == old ? new : path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path }
            let notes = try loadLibrary(); guard notes.failures.isEmpty else { throw LibraryError.invalid("Repair damaged notes before renaming folders.") }
            let changed = notes.notes.filter { LibraryFolders.contains(old, note: $0) }.map { note -> LibraryNote in var value = note; value.folder = moved(note.folder!); value.revision += 1; value.updatedAt = Date(); return value }
            try save(notes: changed, libraryFolders: LibraryFolders.expanded(existing.map(moved)), message: "Rename Library folder")
            // Only remove old empty directories; never discard unexpected files.
            let base = root.appendingPathComponent("notes/" + old)
            if let children = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
                let dirs = children.compactMap { $0 as? URL }.sorted { $0.path.count > $1.path.count }
                for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true { try? FileManager.default.removeItem(at: dir) }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty) == true { try? FileManager.default.removeItem(at: base) }
        }
    }
}
