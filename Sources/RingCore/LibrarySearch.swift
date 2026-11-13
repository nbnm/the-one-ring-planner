import Foundation

public struct LibraryDerivedEntry: Codable, Sendable {
    public var revision: Int
    public var extractedText: String
    public var embedding: [Double]?
    public var embeddingConfiguration: String?
    public init(revision: Int, extractedText: String = "", embedding: [Double]? = nil, embeddingConfiguration: String? = nil) {
        self.revision = revision; self.extractedText = extractedText; self.embedding = embedding; self.embeddingConfiguration = embeddingConfiguration
    }
}
public enum LibraryCollection: String, CaseIterable, Sendable { case all = "All notes", unreviewed = "Unreviewed", favorites = "Favorites" }
public enum LibrarySearch {
    public static func matches(_ notes: [LibraryNote], query: String, collection: LibraryCollection = .all, tag: String = "", kind: LibraryKind? = nil, derived: [String: LibraryDerivedEntry] = [:], archived: Bool = false, trash: Bool = false) -> [LibraryNote] {
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return notes.compactMap { note -> (LibraryNote, Int)? in
            guard (note.trashedAt != nil) == trash, trash || note.archived == archived,
                  collection != .unreviewed || note.unreviewed, collection != .favorites || note.favorite,
                  tag.isEmpty || note.displayTags.contains(tag), kind == nil || note.displayKinds.contains(kind!) else { return nil }
            let title = fold(note.displayTitle), tags = fold(note.displayTags.joined(separator: " "))
            let text = fold([note.body, note.prompt, note.comments, note.sourceURL, note.enrichment?.summary ?? "", derived[note.id]?.extractedText ?? ""].joined(separator: "\n"))
            guard terms.allSatisfy({ title.contains($0) || tags.contains($0) || text.contains($0) }) else { return nil }
            return (note, terms.reduce(0) { $0 + (title.contains($1) ? 5 : 0) + (tags.contains($1) ? 3 : 0) + (text.contains($1) ? 1 : 0) })
        }.sorted { $0.1 == $1.1 ? $0.0.updatedAt > $1.0.updatedAt : $0.1 > $1.1 }.map(\.0)
    }
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let x = sqrt(a.reduce(0) { $0 + $1 * $1 }), y = sqrt(b.reduce(0) { $0 + $1 * $1 })
        guard x > 0, y > 0 else { return nil }
        return zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } / (x*y)
    }
    public static func semantic(_ notes: [LibraryNote], vector: [Double], configuration: String, derived: [String: LibraryDerivedEntry]) -> [LibraryNote] {
        notes.compactMap { note -> (LibraryNote, Double)? in
            guard let d = derived[note.id], d.revision == note.revision, d.embeddingConfiguration == configuration,
                  let v = d.embedding, let score = cosine(vector, v), score > 0.15 else { return nil }
            return (note,score)
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
public enum LibraryPortable {
    public static func export(_ note: LibraryNote, repository: DataRepository, to directory: URL) throws {
        try note.validate()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw LibraryError.invalid("Choose a new export folder so existing files are preserved.") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Preserve exact reusable text as standalone UTF-8 files as well as the reader document.
        try Data(note.body.utf8).write(to: directory.appendingPathComponent("body.md"), options: .atomic)
        try Data(note.prompt.utf8).write(to: directory.appendingPathComponent("prompt.md"), options: .atomic)
        try Data(note.comments.utf8).write(to: directory.appendingPathComponent("comments.md"), options: .atomic)
        var markdown = "# \(note.displayTitle)\n\n" + note.body
        if !note.prompt.isEmpty { markdown += "\n\n[Reusable prompt](prompt.md)\n" }
        if !note.comments.isEmpty { markdown += "\n\n[Comments](comments.md)\n" }
        if !note.sourceURL.isEmpty { markdown += "\n\nSource: \(note.sourceURL)\n" }
        for a in note.attachments {
            let source = try repository.validatedURL(a.path), bytes = try Data(contentsOf: source)
            guard LibraryHash.digest(bytes) == a.hash else { throw LibraryError.invalid("An attachment is missing or corrupt. The incomplete export is preserved for inspection.") }
            let relative = "attachments/\(a.hash).\(a.fileExtension)"
            let destination = directory.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
            markdown += "\n\n\(a.isImage ? "!" : "")[Attachment](\(relative))\n"
        }
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("note.md"), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note.originals).write(to: directory.appendingPathComponent("original-captures.json"), options: .atomic)
    }
}
