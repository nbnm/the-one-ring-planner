import Foundation
import RingCore

final class PersonalAndFolderTests {
    let settings = PlanningSettings()
    var monday: Date { ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")! }
    var saturday: Date { ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")! }
    func at(_ minute: Int, _ day: Date) -> Date { PlannerDate.at(minute, on: day, settings: settings) }
    func task(_ area: TaskArea, id: String = UUID().uuidString.lowercased()) -> PlannerTask {
        var value = PlannerTask(id: id, title: area == .personal ? "Buy provisions for Bilbo" : "Review the Fellowship proposal", tags: ["Fellowship", area.rawValue], state: .ready, importance: true, urgency: false, remainingMinutes: 30, now: at(420, monday))
        value.minimumBlockMinutes = 15; return value
    }
    func testTagsAndLegacyCompatibility() throws {
        XCTAssertEqual(TaskTags.normalize(["Fellowship", "personal", " #Work "]), ["Fellowship", "Work"])
        var value = PlannerTask(title: "Existing task", tags: ["Fellowship"])
        XCTAssertEqual(value.area, .work)
        value.area = .personal; XCTAssertEqual(value.tags, ["Fellowship", "Personal"])
        value.area = .work; XCTAssertEqual(value.tags, ["Fellowship", "Work"])
        XCTAssertTrue(TaskTagFilter.tag("Personal").matches(task(.personal)))
        XCTAssertFalse(TaskTagFilter.tag("Work").matches(task(.personal)))
        let e = JSONEncoder(); let d = JSONDecoder()
        var object = try JSONSerialization.jsonObject(with: e.encode(settings)) as! [String: Any]; object.removeValue(forKey: "personalAvailability")
        XCTAssertEqual(try d.decode(PlanningSettings.self, from: JSONSerialization.data(withJSONObject: object)), settings)
        var customized = settings; var window = PersonalAvailability(); window.weekdayStart = 1140; window.weekdayEnd = 1320; customized.personalAvailability = window
        XCTAssertEqual(try d.decode(PlanningSettings.self, from: e.encode(customized)).taskWindow(.personal, on: monday).start, 1140)
        window.weekendEnd = 0; customized.personalAvailability = window; XCTAssertFalse(customized.isValid)
    }
    func testMixedPlansAndWeekendAvailability() {
        let work = task(.work), personal = task(.personal)
        let meeting = PlanBlock(id: "evening-call", title: "Council", kind: .meeting, start: at(1080, monday), end: at(1140, monday))
        let c = PlannerDate.calendar(settings), dayStart = c.startOfDay(for: monday)
        let read = CalendarRead(interval: DateInterval(start: dayStart, end: c.date(byAdding: .day, value: 1, to: dayStart)!), calendarIDs: ["synthetic"], events: [CalendarOccurrence(id: "late", calendarID: "synthetic", title: "Council", calendarTitle: "Example", start: meeting.start, end: meeting.end)])
        XCTAssertEqual(try? read.meetings(day: monday, settings: settings).count, 0)
        XCTAssertEqual(try? read.meetings(day: monday, settings: settings, fullDay: true).count, 1)
        let scheduler = Scheduler()
        let plan = scheduler.makePlan(day: monday, now: at(420, monday), tasks: [personal, work], routines: [], settings: settings, meetings: [meeting])
        let personalBlocks = plan.blocks.filter { $0.taskID == personal.id }
        XCTAssertEqual(personalBlocks.count, 1)
        XCTAssertGreaterThanOrEqual(personalBlocks.first?.start ?? .distantPast, at(1150, monday))
        XCTAssertLessThanOrEqual(personalBlocks.first?.end ?? .distantFuture, at(1260, monday))
        XCTAssertLessThanOrEqual(plan.blocks.first { $0.taskID == work.id }!.end, at(settings.workEnd, monday))
        let workOnly = scheduler.makePlan(day: monday, now: at(420, monday), tasks: [work], routines: [], settings: settings)
        XCTAssertGreaterThanOrEqual(plan.freeMinutes, workOnly.freeMinutes - settings.relatedTransition)
        let weekend = scheduler.makePlan(day: saturday, now: at(420, saturday), tasks: [personal, work], routines: [], settings: settings)
        XCTAssertTrue(weekend.blocks.contains { $0.taskID == personal.id })
        XCTAssertFalse(weekend.blocks.contains { $0.taskID == work.id })
        let preview = scheduler.preview(day: monday, now: at(420, monday), tasks: [personal, work], routines: [], settings: settings, meetings: [meeting])
        XCTAssertEqual(preview.scheduledEffortMinutes, 60)
        XCTAssertLessThanOrEqual(preview.personalAvailableMinutes, 120)
        let p = scheduler.makePlan(day: monday, now: at(420, monday), tasks: [personal], routines: [], settings: settings, meetings: [PlanBlock(id: "busy", title: "Busy", kind: .meeting, start: at(1080, monday), end: at(1260, monday))])
        XCTAssertFalse(p.blocks.contains { $0.taskID == personal.id })
    }
    func testPersonalSlotSearchAndBookingPreservesIdentity() {
        let personal = task(.personal)
        let busy = PlanBlock(id: "garden", title: "Garden party", kind: .meeting, start: at(600, saturday), end: at(660, saturday))
        let options = TaskSlotPlanner.suggestions(task: personal, minutes: 30, day: saturday, now: at(420, saturday), tasks: [personal], routines: [], settings: settings, meetings: [busy], previous: nil, notBeforeMinute: 0)
        XCTAssertFalse(options.isEmpty)
        guard let slot = options.first else { return }
        XCTAssertGreaterThanOrEqual(slot.start, at(670, saturday))
        let assessment = TaskSlotPlanner.assessment(slot, task: personal, now: at(420, saturday), tasks: [personal], routines: [], settings: settings, meetings: [busy], previous: nil)
        XCTAssertTrue(assessment.canBook); XCTAssertFalse(assessment.warnings.contains { $0.contains("weekend") || $0.contains("work hours") || $0.contains("reserve") })
        let plan = TaskSlotPlanner.accepting(slot, task: personal, now: at(420, saturday), tasks: [personal], routines: [], settings: settings, meetings: [busy], previous: nil)
        let events = CalendarPlanEvent.events(plan: plan, workspaceID: UUID().uuidString.lowercased(), timeZone: settings.timeZone)
        XCTAssertTrue(events.contains { $0.taskID == personal.id && $0.start == slot.start && $0.end == slot.end })
        let overlapping = TaskTimeSlot(taskID: personal.id, start: busy.start, end: busy.start.addingTimeInterval(1800))
        XCTAssertFalse(TaskSlotPlanner.assessment(overlapping, task: personal, now: at(420, saturday), tasks: [personal], routines: [], settings: settings, meetings: [busy], previous: nil).canBook)
    }
    func testFoldersMoveRenameRestartAndArchive() throws {
        let (base, repo) = try LibraryTests().workspace(); defer { try? FileManager.default.removeItem(at: base) }
        try repo.createLibraryFolder("Shire/Recipes"); try repo.createLibraryFolder("Empty")
        let original = LibraryNote(title: "Second breakfast", body: "Mushrooms, then tea.")
        try repo.saveLibrary(original, expectedRevision: nil)
        var moved = original; moved.folder = "Shire/Recipes"; moved.revision += 1
        try repo.saveLibrary(moved, expectedRevision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(original.recordPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(moved.recordPath).path))
        XCTAssertEqual(try repo.loadLibrary().notes.count, 1)
        XCTAssertEqual(try repo.loadLibrary().notes.first?.originals, original.originals)
        XCTAssertTrue(LibraryFolders.contains("Shire", note: moved))
        XCTAssertFalse(LibraryFolders.contains("", note: moved))
        XCTAssertThrowsError(try repo.saveLibrary(original, expectedRevision: 1))
        try repo.renameLibraryFolder("Shire", to: "Bag End")
        let loaded = try repo.loadLibrary().notes.first!
        XCTAssertEqual(loaded.folder, "Bag End/Recipes"); XCTAssertEqual(loaded.body, original.body)
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertTrue(try reopened.libraryFolders().contains("Empty"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("notes/Empty").path))
        XCTAssertEqual(try reopened.loadLibrary().notes.count, 1)
        let archive = base.appendingPathComponent("Archive")
        try LibraryArchive.create(repository: reopened, destination: archive)
        let restored = try LibraryArchive.restoreArchive(archive, into: base.appendingPathComponent("Restored"))
        let restoredRepo = try DataRepository(root: restored.workspace.appendingPathComponent("Data"), localState: restored.workspace.appendingPathComponent("Local"))
        XCTAssertEqual(try restoredRepo.loadLibrary().notes.first?.folder, "Bag End/Recipes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredRepo.root.appendingPathComponent("notes/Empty").path))
    }
    func testFolderSafetyAndRecovery() throws {
        let (base, repo) = try LibraryTests().workspace(); defer { try? FileManager.default.removeItem(at: base) }
        for name in ["../Escape", "/Absolute", "A//B", "A/../B", ".hidden", "A\\B", "A/ B", "A:", "A\nB"] { XCTAssertThrowsError(try repo.createLibraryFolder(name)) }
        let outside = base.appendingPathComponent("Outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("notes/Link"), withDestinationURL: outside)
        XCTAssertThrowsError(try repo.createLibraryFolder("Link/Unsafe"))
        // Recover the intentionally rejected transaction only after the test link is removed.
        if FileManager.default.fileExists(atPath: repo.localState.appendingPathComponent("pending-write.json").path) { try FileManager.default.removeItem(at: repo.localState.appendingPathComponent("pending-write.json")) }
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("notes/Link"))
        try repo.createLibraryFolder("Safe")
        var note = LibraryNote(body: "Recoverable original"); try repo.saveLibrary(note, expectedRevision: nil)
        let oldPath = note.recordPath
        try Data("blocked".utf8).write(to: repo.root.appendingPathComponent(".git/index.lock"))
        note.folder = "Safe"; note.revision += 1
        XCTAssertThrowsError(try repo.saveLibrary(note, expectedRevision: 1))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/index.lock"))
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.loadLibrary().notes.first?.folder, "Safe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(oldPath).path))
        XCTAssertFalse(LibraryArchive.safePath("Data/notes/../outside.json"))
    }
}
