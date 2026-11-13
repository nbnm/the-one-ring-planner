import Foundation

public enum RepositoryError: LocalizedError {
    case git(String), invalidPath, corrupt(String)
    public var errorDescription: String? {
        switch self { case .git(let s): return "Local Git save failed: \(s)"; case .invalidPath: return "Invalid data path."; case .corrupt(let s): return "Could not read \(s). Your files have been preserved." }
    }
}

/// Separate from the application source repository. A durable write-ahead journal repairs partial writes.
public final class DataRepository: @unchecked Sendable {
    private let mutationLock: NSRecursiveLock
    public func withExclusiveAccess<T>(_ work: () throws -> T) rethrows -> T {
        mutationLock.lock(); defer { mutationLock.unlock() }; return try work()
    }
    public let root: URL
    public let localState: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default
    private struct Write: Codable { let path: String; let content: Data }
    private struct Journal: Codable { let writes: [Write]; let deletes: [String]?; let message: String; let attachments: [RepositoryAttachmentWrite]? }
    public init(root: URL, localState: URL) throws {
        self.root = root; self.localState = localState
        mutationLock = try RepositoryMutationLocks.shared.lock(for: root, localState: localState)
        mutationLock.lock(); defer { mutationLock.unlock() }
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: localState, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: root.appendingPathComponent(".git").path) { _ = try git(["init", "--initial-branch=main"]) }
        try recover()
        try materializeLibraryFolders()
    }
    public func load<T: Decodable>(_ type: T.Type, directory: String) throws -> [T] {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard !directory.contains("/"), !directory.contains("..") else { throw RepositoryError.invalidPath }
        let dir = root.appendingPathComponent(directory)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            do { return try decoder.decode(type, from: Data(contentsOf: $0)) } catch { throw RepositoryError.corrupt($0.lastPathComponent) }
        }
    }
    public func settings() throws -> PlanningSettings {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let file = root.appendingPathComponent("settings/planning.json")
        guard fm.fileExists(atPath: file.path) else { return PlanningSettings() }
        do {
            let result = try decoder.decode(PlanningSettings.self, from: Data(contentsOf: file))
            guard result.isValid else { throw RepositoryError.corrupt("settings/planning.json") }
            return result
        } catch { throw RepositoryError.corrupt("settings/planning.json") }
    }
    public func workspaceID() throws -> String {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let file = localState.appendingPathComponent("workspace-id.json")
        if fm.fileExists(atPath: file.path) {
            guard let id = try? decoder.decode(String.self, from: Data(contentsOf: file)), UUID(uuidString: id) != nil else { throw RepositoryError.corrupt("workspace-id.json") }
            return id
        }
        let id = UUID().uuidString.lowercased()
        try encoder.encode(id).write(to: file, options: .atomic)
        return id
    }
    public func save(tasks: [PlannerTask] = [], captures: [Capture] = [], routines: [Routine] = [], completions: [TaskCompletion] = [], calendarEdits: [CalendarBlockEdit] = [], plan: DayPlan? = nil, plans: [DayPlan] = [], deletingTaskIDs: [String] = [], settings: PlanningSettings? = nil, notes: [LibraryNote] = [], inboxItems: [InboxItem] = [], libraryReceipts: [LibraryImportReceipt] = [], attachments: [RepositoryAttachmentWrite] = [], libraryFolders: [String]? = nil, message: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        try recover()
        var writes: [Write] = []
        var movedPaths: [String] = []
        if !notes.isEmpty {
            let loaded = try loadLibrary()
            let current = Dictionary(uniqueKeysWithValues: loaded.notes.map { ($0.id, $0) })
            for note in notes {
                try note.validate()
                if let old = current[note.id], old.recordPath != note.recordPath { movedPaths.append(old.recordPath) }
                writes.append(try record(note, path: note.recordPath))
            }
        }
        if let libraryFolders {
            let folders = try LibraryFolders.expanded(libraryFolders)
            for folder in folders { _ = try validatedURL("notes/" + folder + "/00000000-0000-0000-0000-000000000000.json") }
            writes.append(try record(folders, path: "settings/library-folders.json"))
        }
        for item in inboxItems {
            try item.validate()
            for asset in item.attachments where !attachments.contains(where: { $0.path == asset.path && $0.hash == asset.hash && $0.byteCount == asset.byteCount }) {
                let bytes = try Data(contentsOf: validatedURL(asset.path))
                guard bytes.count == asset.byteCount, LibraryHash.digest(bytes) == asset.hash else { throw LibraryError.invalid("An Inbox image is missing or damaged. Your capture is retained.") }
            }
            writes.append(try record(item, path: "inbox-items/\(item.id).json"))
        }
        for receipt in libraryReceipts { guard LibraryHash.isValid(receipt.id) else { throw RepositoryError.invalidPath }; writes.append(try record(receipt, path: "note-imports/\(receipt.id).json")) }
        for t in tasks {
            guard t.attachments.count <= 100, Set(t.attachments.map(\.hash)).count == t.attachments.count else { throw LibraryError.invalid("Use up to 100 distinct task images.") }
            for asset in t.attachments {
                try asset.validate()
                if !attachments.contains(where: { $0.path == asset.path && $0.hash == asset.hash && $0.byteCount == asset.byteCount }) {
                    let data = try Data(contentsOf: validatedURL(asset.path))
                    guard data.count == asset.byteCount, LibraryHash.digest(data) == asset.hash else { throw LibraryError.invalid("A task image is missing or damaged. Restore its original before saving.") }
                }
            }
            writes.append(try record(t, path: "tasks/\(t.id).json"))
        }
        let extraBytes = Dictionary(attachments.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values.filter { !fm.fileExists(atPath: root.appendingPathComponent($0.path).path) }.reduce(0) { $0 + $1.byteCount }
        if extraBytes > 0 { guard try assetByteCount() + extraBytes <= LibraryPolicy.maximumAssetBytes else { throw LibraryError.invalid("The 256 MB attachment limit is reached. Your capture is retained.") } }

        for c in captures { writes.append(try record(c, path: "captures/\(c.id).json")) }
        for r in routines { writes.append(try record(r, path: "routines/\(r.id).json")) }
        for c in completions { writes.append(try record(c, path: "completions/\(c.id).json")) }
        for e in calendarEdits { writes.append(try record(e, path: "calendar-edits/\(e.id).json")) }
        if let plan { writes.append(try record(plan, path: "plans/\(plan.id).json")) }
        for p in plans { writes.append(try record(p, path: "plans/\(p.id).json")) }
        if let settings { writes.append(try record(settings, path: "settings/planning.json")) }
        let deletes = Array(Set(deletingTaskIDs.map { "tasks/\($0).json" } + movedPaths)).sorted()
        for path in deletes { try validate(path) }
        guard Set(writes.map(\.path)).isDisjoint(with: deletes) else { throw RepositoryError.invalidPath }
        guard !writes.isEmpty || !deletes.isEmpty || !attachments.isEmpty else { return }
        // Do not supersede an unfinished transaction.
        try recover()
        let journal = Journal(writes: writes, deletes: deletes, message: message, attachments: attachments)
        try encoder.encode(journal).write(to: localState.appendingPathComponent("pending-write.json"), options: .atomic)
        try apply(journal)
    }
    public func commitCount() throws -> Int { try withExclusiveAccess { Int(try git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 } }
    public func gitRead(_ args: [String]) throws -> String { try withExclusiveAccess { try git(args) } }
    public func validatedURL(_ path: String) throws -> URL { try withExclusiveAccess { try validate(path); return root.appendingPathComponent(path) } }
    private func record<T: Encodable>(_ value: T, path: String) throws -> Write {
        try validate(path)
        return Write(path: path, content: try encoder.encode(value))
    }
    private func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains(".."), !path.contains("\\"), !path.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty }), parts.count >= 2 else { throw RepositoryError.invalidPath }
        if parts.count > 2 {
            guard parts[0] == "notes", let filename = parts.last, filename.hasSuffix(".json"), UUID(uuidString: String(filename.dropLast(5))) != nil else { throw RepositoryError.invalidPath }
            try LibraryFolders.validate(parts.dropFirst().dropLast().joined(separator: "/"))
        }
        var candidate = root
        for part in path.split(separator: "/") {
            candidate.appendPathComponent(String(part))
            if fm.fileExists(atPath: candidate.path), (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw RepositoryError.invalidPath }
        }
    }
    public func recoverPendingWrites() throws { try withExclusiveAccess { try recover() } }
    private func recover() throws {
        let file = localState.appendingPathComponent("pending-write.json")
        guard fm.fileExists(atPath: file.path) else { return }
        let journal = try decoder.decode(Journal.self, from: Data(contentsOf: file))
        try apply(journal)
    }
    private func apply(_ journal: Journal) throws {
        for path in journal.writes.map(\.path) + (journal.deletes ?? []) { try validate(path) }
        let assetWrites = journal.attachments ?? []
        for asset in assetWrites {
            try validate(asset.path)
            try asset.install(root: root, localState: localState)
        }
        for write in journal.writes {
            let file = root.appendingPathComponent(write.path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write.content.write(to: file, options: .atomic)
        }
        let deletes = journal.deletes ?? []
        for path in deletes {
            let file = root.appendingPathComponent(path)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        if !deletes.isEmpty { _ = try git(["rm", "--cached", "--ignore-unmatch", "--"] + deletes) }
        let paths = Array(Set(journal.writes.map(\.path) + deletes + assetWrites.map(\.path))).sorted()
        let additions = Array(Set(journal.writes.map(\.path) + assetWrites.map(\.path))).sorted()
        if !additions.isEmpty { _ = try git(["add", "--"] + additions) }
        let status = try git(["diff", "--cached", "--name-only", "--"] + paths)
        if !status.isEmpty {
            _ = try git(["-c", "user.name=The One Ring Planner", "-c", "user.email=planner@localhost", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--only", "-m", journal.message, "--"] + paths)
        }
        try materializeLibraryFolders()
        try fm.removeItem(at: localState.appendingPathComponent("pending-write.json"))
        for asset in assetWrites { try? fm.removeItem(at: localState.appendingPathComponent(asset.stagedPath)) }
    }
    private func materializeLibraryFolders() throws {
        let file = try validatedURL("settings/library-folders.json")
        guard fm.fileExists(atPath: file.path) else { return }
        for folder in try JSONDecoder().decode([String].self, from: Data(contentsOf: file)) {
            try LibraryFolders.validate(folder)
            _ = try validatedURL("notes/" + folder + "/00000000-0000-0000-0000-000000000000.json")
            try fm.createDirectory(at: root.appendingPathComponent("notes/" + folder), withIntermediateDirectories: true)
        }
    }
    private func git(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", root.path] + args
        let output = Pipe(), errors = Pipe(); p.standardOutput = output; p.standardError = errors
        try p.run()
        // Drain before wait so a large repository listing cannot fill the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RepositoryError.git(String(data: errorData, encoding: .utf8) ?? "Git exited unsuccessfully.") }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class RepositoryMutationLocks: @unchecked Sendable {
    static let shared = RepositoryMutationLocks()
    private let mutex = NSLock()
    private var locks: [String: (NSRecursiveLock, String)] = [:]
    func lock(for root: URL, localState: URL) throws -> NSRecursiveLock {
        mutex.lock(); defer { mutex.unlock() }
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let journalRoot = localState.standardizedFileURL.resolvingSymlinksInPath().path
        if let value = locks[key] { guard value.1 == journalRoot else { throw LibraryError.invalid("A data working tree must use one shared journal location.") }; return value.0 }
        let value = NSRecursiveLock(); locks[key] = (value, journalRoot); return value
    }
}
