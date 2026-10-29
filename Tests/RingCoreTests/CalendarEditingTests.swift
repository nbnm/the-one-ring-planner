import Foundation
import RingCore

struct CalendarEditingTests {
    let fixture = CalendarScheduleTests()
    func testGeometryAndDST() {
        let f = CalendarGridTests(), start = f.date(540), end = f.date(600)
        let target = f.date(663).addingTimeInterval(12)
        let moved = CalendarEditGeometry.proposal(start: start, end: end, target: target, edge: .move)
        XCTAssertEqual(moved.start, f.date(665)); XCTAssertEqual(moved.duration, 3600)
        let collapsed = CalendarEditGeometry.proposal(start: start, end: end, target: start, edge: .end)
        XCTAssertEqual(collapsed.duration, 300)
        XCTAssertEqual(CalendarEditGeometry.proposal(start: start, end: end, target: end, edge: .start).duration, 300)
        XCTAssertEqual(CalendarEditGeometry.proposal(start: start, end: end, target: end.addingTimeInterval(200000), edge: .end).duration, 86400)
        let beforeDST = ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z")!
        let across = CalendarEditGeometry.proposal(start: start, end: end.addingTimeInterval(3600), target: beforeDST, edge: .move)
        XCTAssertEqual(across.duration, 7200)
        XCTAssertEqual(PlannerDate.calendar(f.settings).component(.hour, from: across.end), 1)
        XCTAssertFalse(CalendarBlockEditing.valid(start: start, end: start))
    }
    func testScopedEditRetainsOtherDraftsAndOwnerIdentity() {
        var p = fixture.published()
        let before = p.publication!, event = before.desired.first!
        let moved = event.rescheduled(start: event.start.addingTimeInterval(86400), end: event.end.addingTimeInterval(88200))
        p.publication = CalendarBlockEditing.recording(moved, in: before, acknowledged: false)
        let i = p.blocks.firstIndex { $0.id == event.blockID }!
        p.blocks[i].start = moved.start; p.blocks[i].end = moved.end; p.blocks[i].calendarOwnerDay = p.id; p.blocks[i].pinned = true
        XCTAssertTrue(p.publication!.matches(p, timeZone: fixture.settings.timeZone))
        XCTAssertEqual(p.publication!.desired.filter { $0.id != event.id }, before.desired.filter { $0.id != event.id })
        XCTAssertEqual(moved.id, event.id); XCTAssertEqual(moved.blockID, event.blockID)
        XCTAssertEqual(p.publication!.lastPublishedEvents, before.lastPublishedEvents)
        let ack = CalendarBlockEditing.recording(moved, in: p.publication!, acknowledged: true)
        XCTAssertTrue(ack.lastPublishedEvents!.contains(moved))
        let projected = CalendarSchedule.plan(on: moved.start, plans: [p], settings: fixture.settings, now: fixture.day, forDisplay: true)!
        XCTAssertEqual(projected.blocks.filter { $0.id == event.blockID }.count, 1)
    }
    func testQueueRestartAndOptimisticOverlay() throws {
        let f = CalendarGridTests(), p = fixture.published(), event = p.publication!.desired.first!
        var scope = p.publication!; scope.desired = [event.rescheduled(start: event.start.addingTimeInterval(3600), end: event.end.addingTimeInterval(5400))]; scope.known = [event]
        var edit = CalendarBlockEdit(publication: scope, baselineStart: event.start, baselineEnd: event.end, creating: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DataRepository(root: root.appendingPathComponent("Data"), localState: root.appendingPathComponent("Local"))
        try repo.save(calendarEdits: [edit], plan: p, message: "Atomic edit")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.load(CalendarBlockEdit.self, directory: "calendar-edits"), [edit])
        let interval = DateInterval(start: f.calendar.startOfDay(for: event.start), duration: 86400)
        let remote = CalendarOccurrence(id: event.id, calendarID: scope.destination.id, title: event.title, calendarTitle: "Work", start: event.start, end: event.end, managedByPlanner: true, plannerCategory: event.category)
        let pending = CalendarGrid.events(in: interval, google: [remote], plans: [p], tasks: [fixture.task], edits: [edit])
        XCTAssertEqual(pending.filter { $0.blockID == event.blockID }.count, 1)
        XCTAssertEqual(pending.first { $0.blockID == event.blockID }?.start, edit.event.start)
        XCTAssertEqual(pending.first { $0.blockID == event.blockID }?.status, .pending)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as! [String: Any]
        var malformed = object["publication"] as! [String: Any]; malformed["desired"] = []; object["publication"] = malformed
        XCTAssertThrowsError(try JSONDecoder().decode(CalendarBlockEdit.self, from: JSONSerialization.data(withJSONObject: object)))
        var older = edit; older.state = .synced; older.syncedAt = Date().addingTimeInterval(-30)
        older.publication.desired = [event]
        edit.state = .synced; edit.syncedAt = Date()
        let latest = CalendarGrid.events(in: interval, google: [remote], plans: [p], tasks: [fixture.task], edits: [edit, older])
        XCTAssertEqual(latest.first { $0.blockID == event.blockID }?.start, edit.event.start)
        XCTAssertEqual(CalendarGrid.events(in: interval, google: [remote], plans: [p], tasks: [fixture.task], edits: [edit], readAt: Date()).first { $0.blockID == event.blockID }?.start, event.start)
    }
    func testTaskResizePreservesHistoryAndOtherChunks() {
        let task = PlannerTask(id: "t", title: "Work", state: .ready, remainingMinutes: 120)
        let updated = CalendarBlockEditing.resizedTask(task, from: 60, to: 90, now: Date())
        XCTAssertEqual(updated.remainingMinutes, 150); XCTAssertEqual(updated.state, .ready)
        XCTAssertEqual(CalendarBlockEditing.resizedTask(task, from: 60, to: 60, now: Date()), task)
        var done = task; done.state = .done; done.completedAt = Date()
        XCTAssertEqual(CalendarBlockEditing.resizedTask(done, from: 60, to: 90, now: Date()), done)
        XCTAssertEqual(CalendarBlockEditing.resizedTask(updated, from: 90, to: 60, now: Date()).remainingMinutes, 120)
    }
}
