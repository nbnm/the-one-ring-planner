import Foundation
import RingCore

final class InboxTests {
    func workspace() throws -> (URL, DataRepository) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-shared-inbox-\(UUID().uuidString)")
        return (base, try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local")))
    }
    func testNeutralCaptureAndNoteRoutingRecoverExactlyOnce() throws {
        let (base, repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("synthetic image bytes".utf8), asset = try LibraryAttachments.prepare(data: bytes, name: "garden.png", extension: "png", localState: repo.localState)
        let text = "# Exact reference\r\n\t`Keep T One A and eight F D E exact`\nhttps://example.com/shire?view=map"
        var item = InboxItem(text: text, attachments: [asset.attachment])
        let captureLock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: captureLock)
        XCTAssertThrowsError(try repo.saveInbox(item, expectedRevision: nil, attachments: [asset.write]))
        try FileManager.default.removeItem(at: captureLock)
        try repo.saveInbox(item, expectedRevision: nil, attachments: [asset.write])
        XCTAssertEqual(try repo.loadInbox().count, 1)
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 0); XCTAssertEqual(try repo.loadLibrary().notes.count, 0)
        item.classification = InboxClassification(kind: .task, title: "Review the garden", tags: ["Shire"]); item.revision += 1
        try repo.saveInbox(item, expectedRevision: 1)
        let replay = InboxItem(id: item.id, text: text, attachments: [asset.attachment], now: item.createdAt)
        XCTAssertEqual(try repo.saveInbox(replay, expectedRevision: nil).classification, item.classification)
        let lock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
        XCTAssertThrowsError(try repo.routeInbox(item, as: .note, settings: PlanningSettings()))
        try FileManager.default.removeItem(at: lock)
        let restarted = try DataRepository(root: repo.root, localState: repo.localState)
        let routed = try restarted.routeInbox(item, as: .note, settings: PlanningSettings())
        XCTAssertEqual(routed.note?.body, text); XCTAssertEqual(routed.note?.originals.first?.text, text)
        XCTAssertEqual(routed.note?.attachments, [asset.attachment]); XCTAssertEqual(routed.note?.sourceURL, "https://example.com/shire?view=map")
        XCTAssertFalse(routed.item.active); XCTAssertEqual(try restarted.loadLibrary().notes.count, 1)
        XCTAssertEqual(try restarted.saveInbox(replay, expectedRevision: nil).route?.kind, .note)
        let changedSource = InboxItem(id: item.id, text: "Attempted replacement", attachments: [asset.attachment], now: item.createdAt)
        XCTAssertThrowsError(try restarted.saveInbox(changedSource, expectedRevision: routed.item.revision))
        XCTAssertEqual(try restarted.load(PlannerTask.self, directory: "tasks").count, 0)
        XCTAssertThrowsError(try restarted.routeInbox(item, as: .task, settings: PlanningSettings()))
        XCTAssertEqual(try Data(contentsOf: restarted.validatedURL(asset.attachment.path)), bytes)
    }
    func testQuadrantNeedsConfirmedDurationAndOverridesSuggestion() throws {
        let (base, repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        var item = InboxItem(text: "A map worth keeping https://example.com/map")
        item.classification = InboxClassification(kind: .note, title: "Fellowship map", tags: ["Fellowship"])
        try repo.saveInbox(item, expectedRevision: nil)
        var task = TaskTriage.proposing(item.task(settings: PlanningSettings()), quadrant: .doFirst)
        XCTAssertThrowsError(try repo.routeInbox(item, as: .task, task: task, settings: PlanningSettings()))
        XCTAssertTrue(try repo.loadInbox().first!.active); XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 0)
        task.title = "Review the Fellowship map"; task.remainingMinutes = 30
        let routed = try repo.routeInbox(item, as: .task, task: task, settings: PlanningSettings())
        XCTAssertEqual(routed.task?.quadrant, .doFirst); XCTAssertEqual(routed.task?.state, .ready); XCTAssertEqual(routed.task?.notes, item.text)
        XCTAssertEqual(routed.task?.sourceCaptureID, item.id); XCTAssertEqual(try repo.load(Capture.self, directory: "captures").first?.text, item.text)
        _ = try repo.routeInbox(item, as: .task, task: task, settings: PlanningSettings())
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 1); XCTAssertEqual(try repo.loadLibrary().notes.count, 0)
    }
    func testLateSuggestionsCannotUndoUserMovesOrEdits() throws {
        let (base, repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let original = InboxItem(text: "Check the garden gate")
        try repo.saveInbox(original, expectedRevision: nil)
        var classified = original; classified.revision += 1; classified.classification = InboxClassification(kind: .task, title: "Check the gate", tags: ["Garden"])
        try repo.saveInbox(classified, expectedRevision: 1)
        // An AI-only revision may complete while the duration form is open.
        var proposed = TaskTriage.proposing(original.task(settings: PlanningSettings()), quadrant: .delegate); proposed.remainingMinutes = 15; proposed.minimumBlockMinutes = 15
        let routed = try repo.routeInbox(original, as: .task, task: proposed, settings: PlanningSettings())
        XCTAssertEqual(routed.task?.tags, ["Garden"])
        var late = classified; late.revision += 1; late.classification = InboxClassification(kind: .note, title: "Late suggestion", tags: [])
        XCTAssertThrowsError(try repo.saveInbox(late, expectedRevision: 2))
        let second = InboxItem(text: "Reference for Bag End"); try repo.saveInbox(second, expectedRevision: nil)
        var edited = second; edited.titleOverride = "Owner’s title"; edited.tagsOverride = ["Owner tag"]; edited.revision += 1; try repo.saveInbox(edited, expectedRevision: 1)
        XCTAssertThrowsError(try repo.routeInbox(second, as: .note, settings: PlanningSettings()))
        let note = try repo.routeInbox(edited, as: .note, settings: PlanningSettings()).note!
        XCTAssertEqual(note.title, "Owner’s title"); XCTAssertEqual(note.tags, ["Owner tag"])
    }
    func testNeutralInboxIncludedInArchiveAndLegacyMoveIsRecoverable() throws {
        let (base, repo) = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let item = InboxItem(text: "Keep this unsorted"); try repo.saveInbox(item, expectedRevision: nil)
        let archive = base.appendingPathComponent("neutral.ringbackup"); try LibraryArchive.create(repository: repo, destination: archive)
        let preview = try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("restored"))
        XCTAssertEqual(preview.inboxCount, 1); XCTAssertEqual(preview.taskCount, 0); XCTAssertEqual(preview.noteCount, 0)
        let reopened = try DataRepository(root: preview.workspace.appendingPathComponent("Data"), localState: preview.workspace.appendingPathComponent("Local"))
        XCTAssertEqual(try reopened.loadInbox().first?.text, item.text)
        var task = PlannerTask(id: "legacy-fixture", title: "Reference disguised as a task", notes: "Exact notes", tags: ["Fellowship"])
        var capture = Capture(text: "Original capture\nhttps://example.com/reference", timeZone: "UTC", taskIDs: [task.id]); task.sourceCaptureID = capture.id
        try repo.save(tasks: [task], captures: [capture], message: "Seed legacy Inbox task")
        let lock = repo.root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
        XCTAssertThrowsError(try repo.moveLegacyInboxTaskToLibrary(task)); try FileManager.default.removeItem(at: lock)
        let moved = try repo.moveLegacyInboxTaskToLibrary(task)
        XCTAssertEqual(moved.note.body, capture.text); XCTAssertEqual(moved.note.tags, task.tags)
        XCTAssertEqual(try repo.load(PlannerTask.self, directory: "tasks").count, 0)
        XCTAssertEqual(try repo.load(Capture.self, directory: "captures").first?.taskIDs, [])
        _ = try repo.moveLegacyInboxTaskToLibrary(task); XCTAssertEqual(try repo.loadLibrary().notes.count, 1)
    }
    func testReferenceLinksAreSafeDistinctAndPreserveSource() throws {
        let text = "Read https://example.com/map?q=shire#section and https://example.com/map?q=shire#section\nAlso https://example.org/path. mailto:bilbo@example.com file:///tmp/private"
        let links = ReferenceLinks.extract(text)
        XCTAssertEqual(links.count, 2); XCTAssertEqual(links.first?.absoluteString, "https://example.com/map?q=shire#section")
        XCTAssertTrue(ReferenceLinks.valid("https://secret@example.com/private") == nil); XCTAssertTrue(ReferenceLinks.valid("javascript:alert(1)") == nil)
        XCTAssertEqual(InboxItem(text: text).text, text)
    }
}
