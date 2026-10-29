import Foundation

public enum RepositoryError: LocalizedError {
    case git(String), invalidPath, corrupt(String)
    public var errorDescription: String? {
        switch self { case .git(let s): return "Local Git save failed: \(s)"; case .invalidPath: return "Invalid data path."; case .corrupt(let s): return "Could not read \(s). Your files have been preserved." }
    }
}

/// Separate from the application source repository. A durable write-ahead journal repairs partial writes.
public final class DataRepository {
    public let root: URL
    public let localState: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default
    private struct Write: Codable { let path: String; let content: Data }
    private struct Journal: Codable { let writes: [Write]; let deletes: [String]?; let message: String }
    public init(root: URL, localState: URL) throws {
        self.root = root; self.localState = localState
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: localState, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: root.appendingPathComponent(".git").path) { _ = try git(["init", "--initial-branch=main"]) }
        try recover()
    }
    public func load<T: Decodable>(_ type: T.Type, directory: String) throws -> [T] {
        let dir = root.appendingPathComponent(directory)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            do { return try decoder.decode(type, from: Data(contentsOf: $0)) } catch { throw RepositoryError.corrupt($0.lastPathComponent) }
        }
    }
    public func settings() throws -> PlanningSettings {
        let file = root.appendingPathComponent("settings/planning.json")
        guard fm.fileExists(atPath: file.path) else { return PlanningSettings() }
        do {
            let result = try decoder.decode(PlanningSettings.self, from: Data(contentsOf: file))
            guard result.isValid else { throw RepositoryError.corrupt("settings/planning.json") }
            return result
        } catch { throw RepositoryError.corrupt("settings/planning.json") }
    }
    public func workspaceID() throws -> String {
        let file = localState.appendingPathComponent("workspace-id.json")
        if fm.fileExists(atPath: file.path) {
            guard let id = try? decoder.decode(String.self, from: Data(contentsOf: file)), UUID(uuidString: id) != nil else { throw RepositoryError.corrupt("workspace-id.json") }
            return id
        }
        let id = UUID().uuidString.lowercased()
        try encoder.encode(id).write(to: file, options: .atomic)
        return id
    }
    public func save(tasks: [PlannerTask] = [], captures: [Capture] = [], routines: [Routine] = [], completions: [TaskCompletion] = [], calendarEdits: [CalendarBlockEdit] = [], plan: DayPlan? = nil, plans: [DayPlan] = [], deletingTaskIDs: [String] = [], settings: PlanningSettings? = nil, message: String) throws {
        var writes: [Write] = []
        for t in tasks { writes.append(try record(t, path: "tasks/\(t.id).json")) }
        for c in captures { writes.append(try record(c, path: "captures/\(c.id).json")) }
        for r in routines { writes.append(try record(r, path: "routines/\(r.id).json")) }
        for c in completions { writes.append(try record(c, path: "completions/\(c.id).json")) }
        for e in calendarEdits { writes.append(try record(e, path: "calendar-edits/\(e.id).json")) }
        if let plan { writes.append(try record(plan, path: "plans/\(plan.id).json")) }
        for p in plans { writes.append(try record(p, path: "plans/\(p.id).json")) }
        if let settings { writes.append(try record(settings, path: "settings/planning.json")) }
        let deletes = Array(Set(deletingTaskIDs.map { "tasks/\($0).json" })).sorted()
        for path in deletes { try validate(path) }
        guard Set(writes.map(\.path)).isDisjoint(with: deletes) else { throw RepositoryError.invalidPath }
        guard !writes.isEmpty || !deletes.isEmpty else { return }
        // Do not supersede an unfinished transaction.
        try recover()
        let journal = Journal(writes: writes, deletes: deletes, message: message)
        try encoder.encode(journal).write(to: localState.appendingPathComponent("pending-write.json"), options: .atomic)
        try apply(journal)
    }
    public func commitCount() throws -> Int { Int(try git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    private func record<T: Encodable>(_ value: T, path: String) throws -> Write {
        try validate(path)
        return Write(path: path, content: try encoder.encode(value))
    }
    private func validate(_ path: String) throws {
        guard !path.contains(".."), !path.hasPrefix("/"), path.split(separator: "/").count == 2 else { throw RepositoryError.invalidPath }
    }
    private func recover() throws {
        let file = localState.appendingPathComponent("pending-write.json")
        guard fm.fileExists(atPath: file.path) else { return }
        let journal = try decoder.decode(Journal.self, from: Data(contentsOf: file))
        try apply(journal)
    }
    private func apply(_ journal: Journal) throws {
        for path in journal.writes.map(\.path) + (journal.deletes ?? []) { try validate(path) }
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
        if !journal.writes.isEmpty { _ = try git(["add", "--"] + journal.writes.map(\.path)) }
        let status = try git(["diff", "--cached", "--name-only"])
        if !status.isEmpty {
            _ = try git(["-c", "user.name=The One Ring Planner", "-c", "user.email=planner@localhost", "-c", "commit.gpgsign=false", "commit", "-m", journal.message])
        }
        try fm.removeItem(at: localState.appendingPathComponent("pending-write.json"))
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
