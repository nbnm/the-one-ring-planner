import Foundation
import RingCore

final class LibraryTests {
    func workspace() throws -> (URL, DataRepository) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ring-library-check-\(UUID().uuidString)")
        return (base, try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local")))
    }
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE9kAAAAASUVORK5CYII=")!
    func testExactTextAttachmentsAndExportSurviveRestart() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let text = "# A skill\r\n\r\n```swift\nlet literal = `keep this`\n```\n" + String(repeating: "Точный текст. ", count: 1100)
        let asset = try LibraryAttachments.prepare(data: image, name: "../../a picture.png", extension: "png", localState: repo.localState)
        let note = LibraryNote(body: text, prompt: "  exact\n\t$(whoami)\n", attachments: [asset.attachment])
        try repo.saveLibrary(note, expectedRevision: nil, attachments: [asset.write])
        let restarted = try DataRepository(root: repo.root, localState: repo.localState)
        let saved = try restarted.loadLibrary().notes[0]
        XCTAssertEqual(saved.body, text); XCTAssertEqual(saved.originals[0].text, text); XCTAssertEqual(saved.reusableText, note.prompt)
        XCTAssertEqual(try Data(contentsOf: restarted.validatedURL(asset.attachment.path)), image)
        XCTAssertEqual(try restarted.load(PlannerTask.self, directory: "tasks").count, 0)
        XCTAssertEqual(try restarted.load(DayPlan.self, directory: "plans").count, 0)
        let export = base.appendingPathComponent("export")
        try LibraryPortable.export(saved, repository: restarted, to: export)
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("body.md")), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("prompt.md")), Data(note.prompt.utf8))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("attachments/\(asset.attachment.hash).png")), image)
    }
    func testAttachmentJournalRecoveryAndScopedCommits() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        try repo.save(tasks: [PlannerTask(id: "first", title: "A fictional task")], message: "Task")
        let unrelated = repo.root.appendingPathComponent("external.txt"); try Data("untouched staging".utf8).write(to: unrelated)
        _ = try LibraryGit.run(root: repo.root, args: ["add", "external.txt"])
        let asset = try LibraryAttachments.prepare(data: image, name: "reference.png", extension: "png", localState: repo.localState)
        let note = LibraryNote(body: "Recover the image with this note", attachments: [asset.attachment])
        let lock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
        XCTAssertThrowsError(try repo.saveLibrary(note, expectedRevision: nil, attachments: [asset.write]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.localState.appendingPathComponent("pending-write.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.localState.appendingPathComponent(asset.write.stagedPath).path))
        try FileManager.default.removeItem(at: lock)
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.loadLibrary().notes.first, note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.localState.appendingPathComponent("pending-write.json").path))
        XCTAssertEqual(try reopened.gitRead(["diff", "--cached", "--name-only"]).trimmingCharacters(in: .whitespacesAndNewlines), "external.txt")
        XCTAssertFalse(try reopened.gitRead(["ls-tree", "--name-only", "HEAD"]).contains("external.txt"))
    }
    func testConcurrentTaskAndNoteWritesShareOneJournal() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let other = try DataRepository(root: repo.root, localState: repo.localState)
        let guardLock = NSLock(); var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                if index % 2 == 0 { try repo.save(tasks: [PlannerTask(id: "parallel-\(index)", title: "Fellowship task \(index)")], message: "Save task") }
                else { try other.saveLibrary(LibraryNote(body: "Reference \(index)"), expectedRevision: nil) }
            } catch { guardLock.lock(); failures.append(error.localizedDescription); guardLock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty); XCTAssertEqual(try repo.loadLibrary().notes.count, 8)
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 8); XCTAssertEqual(try repo.commitCount(), 16)
    }
    func testCorruptNotesAndUnsafeAssetsDoNotHidePlannerData() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        try repo.save(tasks: [PlannerTask(id: "safe", title: "Keep this task")], message: "Save task")
        let note = LibraryNote(body: "A readable note"); try repo.saveLibrary(note, expectedRevision: nil)
        let broken = repo.root.appendingPathComponent("notes/\(UUID().uuidString.lowercased()).json"); try Data("{broken".utf8).write(to: broken)
        let load = try repo.loadLibrary(); XCTAssertEqual(load.notes.count, 1); XCTAssertEqual(load.failures.count, 1)
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").first?.title, "Keep this task")
        let outside = base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("note-assets"), withDestinationURL: outside)
        let asset = try LibraryAttachments.prepare(data: image, name: "x.png", extension: "png", localState: repo.localState)
        XCTAssertThrowsError(try repo.saveLibrary(LibraryNote(attachments: [asset.attachment]), expectedRevision: nil, attachments: [asset.write]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).count, 0)
    }
    func testUserCorrectionsAndStaleOrganization() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let note = LibraryNote(body: "An original prompt"); try repo.saveLibrary(note, expectedRevision: nil)
        let result = LibraryEnrichment(inputRevision: 1, title: "Suggested title", summary: "Summary", tags: ["AI tag"], kinds: [.prompt], model: "mock-model")
        var edited = note; edited.revision = 2; edited.title = "My title"; edited.tags = ["My tag"]; edited.userFields = ["title", "tags"]
        try repo.saveLibrary(edited, expectedRevision: 1)
        XCTAssertThrowsError(try edited.applying(result))
        XCTAssertThrowsError(try repo.saveLibrary(note.applying(result), expectedRevision: 1))
        var fresh = result; fresh.inputRevision = 2
        let enriched = try edited.applying(fresh)
        XCTAssertEqual(enriched.displayTitle, "My title"); XCTAssertEqual(enriched.displayTags, ["My tag"]); XCTAssertEqual(enriched.body, note.body)
        var optedOut = edited; optedOut.automationAllowed = false; XCTAssertThrowsError(try optedOut.applying(fresh))
    }
    func testOfflineSearchTrashAndSemanticRevisionFiltering() throws {
        var note = LibraryNote(title: "Rivendell", body: "Exact source text"); note.tags = ["Fellowship"]; note.favorite = true
        let derived = [note.id: LibraryDerivedEntry(revision: 1, extractedText: "Тихая библиотека", embedding: [1,0], embeddingConfiguration: "test")]
        XCTAssertEqual(LibrarySearch.matches([note], query: "библиотека", derived: derived).count, 1)
        XCTAssertEqual(LibrarySearch.matches([note], query: "fellowship", collection: .favorites).count, 1)
        XCTAssertEqual(LibrarySearch.semantic([note], vector: [1,0], configuration: "test", derived: derived).count, 1)
        note.revision += 1; XCTAssertEqual(LibrarySearch.semantic([note], vector: [1,0], configuration: "test", derived: derived).count, 0)
        note.trashedAt = Date(); XCTAssertEqual(LibrarySearch.matches([note], query: "").count, 0)
        XCTAssertEqual(LibrarySearch.matches([note], query: "", trash: true).count, 1)
        note.trashedAt = nil; note.archived = true; XCTAssertEqual(LibrarySearch.matches([note], query: "", archived: true).count, 1)
    }
    func testTelegramDuplicatesAlbumsAndFailedCommitReceipts() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let hash = LibraryHash.digest(image), file = LibraryTelegramFile(hash: hash, byteCount: image.count, name: "album.png", fileExtension: "png")
        let first = LibraryTelegramItem(id: "tg:owner:1", text: "Caption\n```code```", capturedAt: Date(timeIntervalSince1970: 100), files: [file])
        let thread = LibraryHash.digest(Data("album".utf8))
        let capture = LibraryTelegramCapture(id: LibraryHash.digest(Data("delivery1".utf8)), threadID: thread, items: [first])
        let lock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
        XCTAssertThrowsError(try LibraryTelegramImporter.importCapture(capture, bytes: [hash:image], repository: repo))
        try FileManager.default.removeItem(at: lock); try repo.recoverPendingWrites()
        let saved = try LibraryTelegramImporter.importCapture(capture, bytes: [hash:image], repository: repo)
        let duplicate = try LibraryTelegramImporter.importCapture(capture, bytes: [hash:image], repository: repo)
        XCTAssertEqual(saved.id, duplicate.id); XCTAssertEqual(try repo.loadLibrary().notes.count, 1)
        let second = LibraryTelegramItem(id: "tg:owner:2", text: "A second album caption", capturedAt: Date(), files: [file])
        let revision = LibraryTelegramCapture(id: LibraryHash.digest(Data("delivery2".utf8)), threadID: thread, items: [first,second])
        let appended = try LibraryTelegramImporter.importCapture(revision, bytes: [hash:image], repository: repo)
        XCTAssertEqual(appended.id, saved.id); XCTAssertEqual(appended.attachments.count, 1); XCTAssertEqual(appended.originals.count, 2)
        XCTAssertEqual(appended.body, first.text + "\n\n" + second.text); XCTAssertTrue(appended.unreviewed)
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 0)
        XCTAssertEqual(try repo.load(LibraryImportReceipt.self, directory: "note-imports").count, 2)
    }
    func testPrivateRemoteAndLFSGuards() throws {
        XCTAssertThrowsError(try LibraryRemoteBackup.githubRepository("https://github.com/nbnm/the-one-ring-planner.git"))
        XCTAssertThrowsError(try LibraryRemoteBackup.githubRepository("https://token@github.com/test/private.git"))
        XCTAssertThrowsError(try LibraryRemoteBackup.githubRepository("https://example.com/data.git"))
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 100\n".utf8)
        let asset = try LibraryAttachments.prepare(data: bytes, name: "pointer.png", extension: "png", localState: repo.localState)
        try repo.saveLibrary(LibraryNote(attachments: [asset.attachment]), expectedRevision: nil, attachments: [asset.write])
        XCTAssertThrowsError(try LibraryRemoteBackup.checkOrdinaryGit(repo))
        XCTAssertFalse(LibraryArchive.safePath("Data/../private.json")); XCTAssertFalse(LibraryArchive.safePath("Data/.git/config"))
    }
    func testVerifiedLocalRemoteConflictAndCleanRestore() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try LibraryAttachments.prepare(data: image, name: "reference.png", extension: "png", localState: repo.localState)
        try repo.saveLibrary(LibraryNote(body: "Restore me", attachments: [asset.attachment]), expectedRevision: nil, attachments: [asset.write])
        let remote = base.appendingPathComponent("private-test.git")
        _ = try LibraryGit.run(root: nil, args: ["init", "--bare", "--initial-branch=main", remote.path])
        var config = LibraryBackupSettings(); config.remoteURL = remote.path
        let commit = try LibraryRemoteBackup.push(repo, settings: config, token: nil, allowLocalTestRemote: true)
        XCTAssertEqual(try LibraryGit.run(root: nil, args: ["--git-dir=\(remote.path)", "rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), commit)
        let preview = try LibraryArchive.restoreRemote(remote.path, token: nil, into: base.appendingPathComponent("remote-restore"), allowLocalTestRemote: true)
        XCTAssertEqual(preview.noteCount, 1)
        let restored = try DataRepository(root: preview.workspace.appendingPathComponent("Data"), localState: preview.workspace.appendingPathComponent("Local"))
        XCTAssertEqual(try Data(contentsOf: restored.validatedURL(asset.attachment.path)), image)
        let other = base.appendingPathComponent("other")
        _ = try LibraryGit.run(root: nil, args: ["clone", remote.path, other.path])
        let writer = try DataRepository(root: other, localState: base.appendingPathComponent("other-local"))
        try writer.saveLibrary(LibraryNote(body: "Other writer"), expectedRevision: nil)
        _ = try LibraryRemoteBackup.push(writer, settings: config, token: nil, allowLocalTestRemote: true)
        try repo.saveLibrary(LibraryNote(body: "Local version"), expectedRevision: nil)
        XCTAssertThrowsError(try LibraryRemoteBackup.push(repo, settings: config, token: nil, allowLocalTestRemote: true))
        XCTAssertEqual(try repo.loadLibrary().notes.count, 2)
    }
    func testIndependentArchiveRestoresBytesAndRejectsTampering() throws {
        let (base,repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try LibraryAttachments.prepare(data: image, name: "reference.png", extension: "png", localState: repo.localState)
        try repo.saveLibrary(LibraryNote(body: "Archive this", attachments: [asset.attachment]), expectedRevision: nil, attachments: [asset.write])
        try repo.save(tasks: [PlannerTask(id: "test-task", title: "Fictional task")], message: "Save task")
        let archive = base.appendingPathComponent("snapshot.ringbackup")
        try LibraryArchive.create(repository: repo, destination: archive)
        let preview = try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("restored"))
        XCTAssertEqual(preview.noteCount, 1); XCTAssertEqual(preview.taskCount, 1); XCTAssertFalse(preview.includesMeetings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.workspace.appendingPathComponent("Local/library-index.json").path))
        try Data("tampered".utf8).write(to: archive.appendingPathComponent("Data/" + asset.attachment.path))
        XCTAssertThrowsError(try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("bad-restore")))
        XCTAssertEqual(try Data(contentsOf: repo.validatedURL(asset.attachment.path)), image)
    }
    func testRequestBudgetAndConfigurationBindings() throws {
        var ledger = LibraryRequestLedger(); let date = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        try ledger.consume(limit: 1, now: date); XCTAssertThrowsError(try ledger.consume(limit: 1, now: date))
        try ledger.consume(limit: 1, now: date.addingTimeInterval(32 * 86400)); XCTAssertEqual(ledger.requests, 1)
        XCTAssertFalse(LibraryCapabilities.key(baseURL: "https://one.example/v1", model: "alias") == LibraryCapabilities.key(baseURL: "https://two.example/v1", model: "alias"))
        XCTAssertTrue(LibrarySearch.cosine([0,0], [1,0]) == nil); XCTAssertTrue(LibrarySearch.cosine([1], [1,2]) == nil)
    }
    func testTaskImagesShareCaptureJournalAndRestore() throws {
        let (base, repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let one = try LibraryAttachments.prepare(data: image, name: "map.png", extension: "png", localState: repo.localState)
        let two = try LibraryAttachments.prepare(data: Data("second synthetic asset".utf8), name: "route.png", extension: "png", localState: repo.localState)
        let batch = try ReviewedCapture(source: "Compare both maps", drafts: [CaptureDraft(title: "Review the map", tags: ["Fellowship"]), CaptureDraft(title: "Check the route", tags: ["Travel"])], settings: PlanningSettings(), attachments: [one.attachment, two.attachment])
        let lock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
        XCTAssertThrowsError(try repo.save(tasks: batch.tasks, captures: [batch.capture], attachments: [one.write,two.write], message: "Capture task images"))
        try FileManager.default.removeItem(at: lock)
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        let tasks = try reopened.load(PlannerTask.self, directory: "tasks")
        XCTAssertEqual(tasks.count, 2); XCTAssertTrue(tasks.allSatisfy { $0.attachments == [one.attachment,two.attachment] })
        XCTAssertEqual(try reopened.load(Capture.self, directory: "captures").first?.attachments, [one.attachment,two.attachment])
        XCTAssertEqual(try Data(contentsOf: reopened.validatedURL(one.attachment.path)), image)
        let archive = base.appendingPathComponent("task-images.ringbackup"); try LibraryArchive.create(repository: reopened, destination: archive)
        let restored = try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("restored-task-images"))
        XCTAssertEqual(restored.taskCount, 2)
        try FileManager.default.removeItem(at: archive.appendingPathComponent("Data/" + one.attachment.path))
        XCTAssertThrowsError(try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("missing-task-image")))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(tasks[0])) as! [String: Any]; legacy.removeValue(forKey: "attachments")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PlannerTask.self, from: JSONSerialization.data(withJSONObject: legacy)).attachments, [])
    }
}
