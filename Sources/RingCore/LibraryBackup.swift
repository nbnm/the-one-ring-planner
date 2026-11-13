import Foundation

public enum LibraryGit {
    /// Credentials live only in this child process's environment, never its URL or arguments.
    public static func run(root: URL?, args: [String], token: String? = nil, timeout: TimeInterval = 90) throws -> String {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("ring-git-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let stdout = folder.appendingPathComponent("out"), stderr = folder.appendingPathComponent("err")
        fm.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600]); fm.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = (root.map { ["-C", $0.path] } ?? []) + ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.ext.allow=never"] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["LC_ALL"] = "C"
        if let token {
            let askpass = folder.appendingPathComponent("askpass")
            try Data("#!/bin/sh\ncase \"$1\" in *Username*) printf '%s' x-access-token ;; *) printf '%s' \"$ONE_RING_BACKUP_TOKEN\" ;; esac\n".utf8).write(to: askpass)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            environment["GIT_ASKPASS"] = askpass.path; environment["ONE_RING_BACKUP_TOKEN"] = token
        }
        process.environment = environment; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw LibraryError.unavailable("Git backup timed out. Check your connection and retry; local data is safe.") }
        process.waitUntilExit()
        let output = (try? String(contentsOf: stdout, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            if error.contains("non-fast-forward") || error.contains("fetch first") || error.contains("rejected") {
                throw LibraryError.unavailable("The remote has another version or rejected this update. Backup is paused. Restore it into a separate preview workspace and reconcile there; your local version is preserved. No merge or force-push was performed.")
            }
            throw LibraryError.unavailable("Git could not complete the backup operation (exit \(process.terminationStatus)). Check private-repository access, token permissions, storage quota and network. Your local version is preserved.")
        }
        guard output.utf8.count <= 8 * 1024 * 1024 else { throw LibraryError.invalid("Git output exceeded the supported small-library limit.") }; return output
    }
}
public enum LibraryRemoteBackup {
    public static func githubRepository(_ remote: String) throws -> (owner: String, name: String) {
        guard let url = URL(string: remote), url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw LibraryError.invalid("Use an explicitly configured private GitHub HTTPS repository. SSH and other hosts are not supported by this backup adapter.") }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { throw LibraryError.invalid("Enter https://github.com/owner/private-repository.git") }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard !(parts[0].lowercased() == "nbnm" && name.lowercased() == "the-one-ring-planner") else { throw LibraryError.invalid("The public application source repository cannot be used for personal data backup.") }
        return (parts[0], name)
    }
    public static func verifyPrivate(_ remote: String, token: String, http: LibraryHTTP = LibraryHTTP()) async throws {
        let repo = try githubRepository(remote)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await http.data(request)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["private"] as? Bool == true, value["archived"] as? Bool != true else { throw LibraryError.invalid("This repository is not a writable private repository. No personal data was uploaded.") }
    }
    public static func checkOrdinaryGit(_ repository: DataRepository) throws {
        try repository.withExclusiveAccess {
            guard try repository.assetByteCount() <= LibraryPolicy.maximumAssetBytes else { throw LibraryError.invalid("The 256 MB small-library limit is exceeded. Export an archive before changing storage policy.") }
            let attributes = repository.root.appendingPathComponent(".gitattributes")
            if let text = try? String(contentsOf: attributes), text.contains("filter=") { throw LibraryError.invalid("Filtered/LFS storage is not supported by this ordinary-Git mode. LFS runtime, remote quota and actual object uploads must be verified before it can be enabled. Use an archive containing actual bytes.") }
            let assets = repository.root.appendingPathComponent("note-assets")
            if FileManager.default.fileExists(atPath: assets.path) {
                for file in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.fileSizeKey]) {
                    let url = try repository.validatedURL("note-assets/\(file.lastPathComponent)")
                    let data = try Data(contentsOf: url)
                    guard data.count <= LibraryPolicy.maximumAttachmentBytes, !data.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8)), LibraryHash.digest(data) == file.deletingPathExtension().lastPathComponent else { throw LibraryError.invalid("An attachment is an LFS pointer, oversized or corrupt. Remote backup cannot be verified without actual attachment bytes.") }
                }
            }
        }
    }
    public static func push(_ repository: DataRepository, settings: LibraryBackupSettings, token: String?, allowLocalTestRemote: Bool = false) throws -> String {
        if !allowLocalTestRemote { _ = try githubRepository(settings.remoteURL); guard settings.verifiedPrivateRemote == settings.remoteURL else { throw LibraryError.invalid("Verify this private remote in Data & backup before uploading.") } }
        let commit = try repository.withExclusiveAccess {
            try repository.recoverPendingWrites(); try checkOrdinaryGit(repository)
            guard try repository.gitRead(["status", "--porcelain"]).isEmpty else { throw LibraryError.unavailable("Local files are saved but not fully committed. Retry the local save before remote backup.") }
            return try repository.gitRead(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Push an immutable committed snapshot. Network I/O never holds the mutation lock.
        _ = try LibraryGit.run(root: repository.root, args: ["push", "--", settings.remoteURL, "\(commit):refs/heads/main"], token: token)
        let remote = try LibraryGit.run(root: nil, args: ["ls-remote", "--", settings.remoteURL, "refs/heads/main"], token: token).split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard remote == commit else { throw LibraryError.unavailable("Remote verification did not match the committed snapshot. Backup has not been marked successful; retry or inspect the remote preview.") }; return commit
    }
}
public struct LibraryArchiveManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable { public let path: String; public let hash: String; public let bytes: Int }
    public let version: Int
    public let createdAt: Date
    public let includesMeetings: Bool
    public let files: [Entry]
}
public enum LibraryArchive {
    private static let dataDirectories: Set<String> = ["tasks", "captures", "routines", "plans", "completions", "calendar-edits", "settings", "notes", "note-assets", "note-imports", "inbox-items"]
    public static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"), parts.allSatisfy({ !$0.isEmpty }), parts.count >= 3 else { return false }
        if parts[0] == "Data" {
            if parts[1] == "notes", parts.count > 3 {
                guard let file = parts.last, file.hasSuffix(".json"), UUID(uuidString: String(file.dropLast(5))) != nil else { return false }
                return (try? LibraryFolders.validate(parts.dropFirst(2).dropLast().joined(separator: "/"))) != nil
            }
            return parts.count == 3 && dataDirectories.contains(String(parts[1]))
        }
        return parts.count == 3 && parts[0] == "Meetings" && UUID(uuidString: String(parts[1])) != nil
    }
    public static func create(repository: DataRepository, meetings: URL? = nil, destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalid("Choose a new archive destination. Existing backups are preserved.") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var entries: [LibraryArchiveManifest.Entry] = [], total = 0
        try repository.withExclusiveAccess {
            try repository.recoverPendingWrites(); try LibraryRemoteBackup.checkOrdinaryGit(repository)
            let sources: [(String, URL)] = [("Data", repository.root)] + (meetings.map { [("Meetings", $0)] } ?? [])
            for (scope, originalBase) in sources {
                let base = originalBase.standardizedFileURL.resolvingSymlinksInPath()
                guard fm.fileExists(atPath: base.path), let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isSymbolicLink != true else { throw LibraryError.invalid("An archive source contains a symbolic link. Inspect it before backup.") }
                    guard values.isRegularFile == true else { continue }
                    let rootParts = base.resolvingSymlinksInPath().pathComponents, fileParts = file.resolvingSymlinksInPath().pathComponents
                    guard Array(fileParts.prefix(rootParts.count)) == rootParts else { throw RepositoryError.invalidPath }
                    let relative = scope + "/" + fileParts.dropFirst(rootParts.count).joined(separator: "/")
                    guard safePath(relative) else { throw LibraryError.invalid("Unsupported archive path: \(relative). Source files are preserved.") }
                    total += values.fileSize ?? 0
                    guard total <= 16 * 1024 * 1024 * 1024, entries.count < 30000 else { throw LibraryError.invalid("This archive exceeds the supported 16 GB / 30,000-file limit.") }
                    let target = destination.appendingPathComponent(relative)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: file, to: target)
                    let data = try Data(contentsOf: target, options: .mappedIfSafe)
                    entries.append(.init(path: relative, hash: LibraryHash.digest(data), bytes: data.count))
                }
            }
        }
        let manifest = LibraryArchiveManifest(version: 1, createdAt: Date(), includesMeetings: meetings != nil, files: entries)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    }
    public static func restoreArchive(_ source: URL, into root: URL) throws -> LibraryRestorePreview {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LibraryArchiveManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, !manifest.files.isEmpty, manifest.files.count <= 30000, Set(manifest.files.map(\.path)).count == manifest.files.count else { throw LibraryError.invalid("Invalid archive manifest. No working data was replaced.") }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw LibraryError.invalid("Restore requires a new, separate workspace.") }
        var total = 0
        for entry in manifest.files {
            guard safePath(entry.path), LibraryHash.isValid(entry.hash), entry.bytes >= 0, manifest.includesMeetings || !entry.path.hasPrefix("Meetings/") else { throw RepositoryError.invalidPath }
            let file = source.appendingPathComponent(entry.path)
            var candidate = source
            for part in entry.path.split(separator: "/") { candidate.appendPathComponent(String(part)); if (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw RepositoryError.invalidPath } }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            total += max(0,size); guard size == entry.bytes, total <= 16 * 1024 * 1024 * 1024 else { throw LibraryError.invalid("Archive byte counts exceed the manifest or supported limit.") }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard LibraryHash.digest(data) == entry.hash else { throw LibraryError.invalid("Archive hash validation failed. The active workspace is unchanged.") }
            let target = root.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        return try validateWorkspace(root, includesMeetings: manifest.includesMeetings)
    }
    public static func restoreRemote(_ remote: String, token: String?, into root: URL, allowLocalTestRemote: Bool = false) throws -> LibraryRestorePreview {
        if !allowLocalTestRemote { _ = try LibraryRemoteBackup.githubRepository(remote) }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw LibraryError.invalid("Remote restore requires a new separate workspace.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clone = root.appendingPathComponent("remote-preview")
        _ = try LibraryGit.run(root: nil, args: ["clone", "--no-checkout", "--", remote, clone.path], token: token)
        let listing = try LibraryGit.run(root: clone, args: ["ls-tree", "-r", "HEAD"])
        for line in listing.split(separator: "\n") {
            let values = line.split(separator: "\t", maxSplits: 1)
            guard values.count == 2, values[0].hasPrefix("100644 ") || values[0].hasPrefix("100755 ") else { throw LibraryError.invalid("The remote contains unsupported links or submodules. Inspect the separate preview.") }
            let path = String(values[1])
            guard path == ".gitattributes" || safePath("Data/" + path) else { throw LibraryError.invalid("The remote includes unsupported files. No active data was changed.") }
        }
        _ = try LibraryGit.run(root: clone, args: ["checkout", "--detach", "HEAD"])
        // The clone remains as a separate conflict/recovery copy. Only validated canonical files enter the new Data repository.
        let data = root.appendingPathComponent("Data"); try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        for directory in dataDirectories {
            let source = clone.appendingPathComponent(directory)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: data.appendingPathComponent(directory)) }
        }
        if FileManager.default.fileExists(atPath: clone.appendingPathComponent(".gitattributes").path) { try FileManager.default.copyItem(at: clone.appendingPathComponent(".gitattributes"), to: data.appendingPathComponent(".gitattributes")) }
        return try validateWorkspace(root, includesMeetings: false)
    }
    public static func validateWorkspace(_ root: URL, includesMeetings: Bool) throws -> LibraryRestorePreview {
        let repo = try DataRepository(root: root.appendingPathComponent("Data"), localState: root.appendingPathComponent("Local"))
        let tasks = try repo.load(PlannerTask.self, directory: "tasks")
        let inbox = try repo.loadInbox()
        _ = try repo.load(Capture.self, directory: "captures"); _ = try repo.load(Routine.self, directory: "routines")
        _ = try repo.load(DayPlan.self, directory: "plans"); _ = try repo.load(TaskCompletion.self, directory: "completions")
        _ = try repo.load(CalendarBlockEdit.self, directory: "calendar-edits"); _ = try repo.load(LibraryImportReceipt.self, directory: "note-imports"); _ = try repo.settings()
        let library = try repo.loadLibrary(); guard library.failures.isEmpty else { throw LibraryError.invalid("The restored workspace contains damaged notes. Its preview is preserved; active data was not changed.") }
        try LibraryRemoteBackup.checkOrdinaryGit(repo)
        for attachment in library.notes.flatMap(\.attachments) + tasks.flatMap(\.attachments) + inbox.flatMap(\.attachments) {
            let bytes = try Data(contentsOf: repo.validatedURL(attachment.path)); guard bytes.count == attachment.byteCount, LibraryHash.digest(bytes) == attachment.hash else { throw LibraryError.invalid("A restored attachment is missing or corrupt.") }
        }
        if includesMeetings { _ = try MeetingRepository(root: root.appendingPathComponent("Meetings")).load() }
        // Fresh local history deliberately has no remote and no imported hooks/configuration.
        _ = try LibraryGit.run(root: repo.root, args: ["add", "--all"])
        if !(try LibraryGit.run(root: repo.root, args: ["diff", "--cached", "--name-only"])).isEmpty {
            _ = try LibraryGit.run(root: repo.root, args: ["-c", "user.name=The One Ring Planner", "-c", "user.email=planner@localhost", "-c", "commit.gpgsign=false", "commit", "-m", "Restore validated workspace snapshot"])
        }
        var derived: [String: LibraryDerivedEntry] = [:]
        for note in library.notes { derived[note.id] = LibraryDerivedEntry(revision: note.revision) }
        let encoder = JSONEncoder(); try encoder.encode(derived).write(to: repo.localState.appendingPathComponent("library-index.json"), options: .atomic)
        return LibraryRestorePreview(workspace: root, noteCount: library.notes.count, taskCount: tasks.count, inboxCount: inbox.filter(\.active).count, includesMeetings: includesMeetings)
    }
}
