import Foundation
import RingCore

struct CalendarScheduleTests {
    let settings = PlanningSettings()
    let workspace = "c139a7a0-5bcf-4f48-a48b-dc02879a0aa6"
    let day = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    var task: PlannerTask { PlannerTask(id: "q2", title: "Prepare release", context: "T1A", state: .ready, importance: true, urgency: false, remainingMinutes: 30) }
    var routine: Routine { Routine(id: "walk", title: "Walk", minutes: 15, startMinute: 900, endMinute: 960, enabled: true) }
    func at(_ minute: Int, day: Date? = nil) -> Date { PlannerDate.at(minute, on: day ?? self.day, settings: settings) }
    func published() -> DayPlan {
        var p = Scheduler().makePlan(day: day, now: at(480), tasks: [task], routines: [routine], settings: settings)
        p.status = .local
        p.publication = CalendarPublication(plan: p, workspaceID: workspace,
            destination: PublicationDestination(id: "work", title: "Work", accountID: "me"), timeZone: settings.timeZone)
        p.publication!.state = .published; p.publication!.known = p.publication!.desired
        return p
    }
    func testMovesPreserveIdentityHistoryAndDoNotDirtyPublication() {
        var p = published()
        let taskIndex = p.blocks.firstIndex { $0.taskID != nil }!, routineIndex = p.blocks.firstIndex { $0.routineID != nil }!
        p.blocks[taskIndex].state = .running; p.blocks[taskIndex].actualStartedAt = at(540)
        p.blocks[routineIndex].state = .completed; p.blocks[routineIndex].actualMinutes = 12
        let times = p.publication!.desired.map { CalendarEventTime(id: $0.id, start: $0.start.addingTimeInterval(600), end: $0.end.addingTimeInterval(900)) }
        let result = CalendarSchedule.reconciling(p, times: times, settings: settings)
        XCTAssertEqual(result.changedEvents, 2); XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.plan.publication!.state, .published)
        XCTAssertTrue(result.plan.publication!.matches(result.plan, timeZone: settings.timeZone))
        XCTAssertEqual(result.plan.publication!.desired.map(\.id), p.publication!.desired.map(\.id))
        XCTAssertEqual(result.plan.blocks.first { $0.taskID != nil }?.actualStartedAt, at(540))
        XCTAssertEqual(result.plan.blocks.first { $0.taskID != nil }?.state, .running)
        XCTAssertEqual(result.plan.blocks.first { $0.routineID != nil }?.actualMinutes, 12)
        XCTAssertEqual(result.plan.blocks.first { $0.routineID != nil }?.state, .completed)
        XCTAssertTrue(result.plan.blocks.filter { $0.kind == .focus || $0.kind == .routine }.allSatisfy { $0.pinned && $0.calendarOwnerDay == p.id })
        XCTAssertEqual(CalendarSchedule.reconciling(result.plan, times: times, settings: settings).plan, result.plan)
    }
    func testCrossDayMovesProjectOnceAndReplanningDoesNotDuplicateOrRepublish() {
        let p = published(), c = PlannerDate.calendar(settings)
        let nextDay = c.date(byAdding: .day, value: 1, to: day)!
        // Toronto changes its UTC offset on this date.
        let times = p.publication!.desired.map { event in
            let start = at(event.routineID == nil ? 600 : 900, day: nextDay)
            return CalendarEventTime(id: event.id, start: start, end: start.addingTimeInterval(event.end.timeIntervalSince(event.start)))
        }
        let moved = CalendarSchedule.reconciling(p, times: times, settings: settings).plan
        let oldDisplay = CalendarSchedule.plan(on: day, plans: [moved], settings: settings, now: at(480), forDisplay: true)!
        XCTAssertFalse(oldDisplay.blocks.contains { $0.kind == .focus || $0.kind == .routine })
        let newDisplay = CalendarSchedule.plan(on: nextDay, plans: [moved], settings: settings, now: at(480), forDisplay: true)!
        XCTAssertEqual(newDisplay.blocks.filter { $0.kind == .focus || $0.kind == .routine }.count, 2)
        XCTAssertEqual(c.component(.hour, from: newDisplay.blocks.first { $0.taskID != nil }!.start), 10)
        let sourceReplan = Scheduler().makePlan(day: day, now: at(480), tasks: [task], routines: [routine], settings: settings, previous: moved)
        XCTAssertEqual(sourceReplan.blocks.filter { $0.taskID != nil }.count, 1)
        XCTAssertEqual(sourceReplan.blocks.filter { $0.routineID != nil }.count, 1)
        XCTAssertTrue(moved.publication!.matches(sourceReplan, timeZone: settings.timeZone))
        let nextPrevious = CalendarSchedule.plan(on: nextDay, plans: [moved], settings: settings, now: at(480))!
        let destinationReplan = Scheduler().makePlan(day: nextDay, now: at(480), tasks: [task], routines: [routine], settings: settings, previous: nextPrevious, selectedTaskIDs: [])
        XCTAssertEqual(destinationReplan.blocks.filter { $0.taskID != nil }.count, 1)
        XCTAssertEqual(destinationReplan.blocks.filter { $0.routineID != nil }.count, 1)
        XCTAssertTrue(CalendarPlanEvent.events(plan: destinationReplan, workspaceID: workspace, timeZone: settings.timeZone).isEmpty)
        let savedDestination = CalendarSchedule.canonical(destinationReplan)
        XCTAssertFalse(savedDestination.blocks.contains { $0.taskID != nil || $0.routineID != nil })
        let again = CalendarSchedule.plan(on: nextDay, plans: [moved, savedDestination], settings: settings, now: at(480), forDisplay: true)!
        XCTAssertEqual(again.blocks.filter { $0.taskID != nil || $0.routineID != nil }.count, 2)
        let preview = Scheduler().preview(day: day, now: at(480), tasks: [task], routines: [routine], settings: settings, previous: moved)
        XCTAssertEqual(preview.scheduledEffortMinutes, 0)
        let entries = TaskScheduleEntry.entries(taskID: task.id, plans: [moved, savedDestination], now: at(480))
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].start, at(600, day: nextDay))
    }
    func testMovesPreserveOtherBlocksAndExposeOverlapsAndWorkBounds() {
        var p = published()
        let event = p.publication!.desired.first { $0.taskID != nil }!
        let other = PlanBlock(id: "fixed", title: "Other fixed work", kind: .meeting, start: at(1020), end: at(1050))
        p.blocks.append(other)
        let moved = CalendarSchedule.reconciling(p, times: [.init(id: event.id, start: at(1020), end: at(1050))], settings: settings).plan
        XCTAssertEqual(moved.blocks.first { $0.id == other.id }, other)
        XCTAssertEqual(moved.blocks.first { $0.taskID != nil }?.start, at(1020))
        XCTAssertTrue(moved.warnings.contains { $0.hasPrefix("Overlap:") })
        XCTAssertTrue(moved.warnings.contains { $0.hasPrefix("Outside work hours:") })
        XCTAssertFalse(moved.blocks.contains { $0.kind == .transition && $0.start == event.end })
    }
    func testLocalConflictsRetainDraftAndRequireConfirmation() {
        var p = published()
        let event = p.publication!.desired.first { $0.taskID != nil }!, index = p.blocks.firstIndex { $0.id == event.blockID }!
        p.blocks[index].start = at(660); p.blocks[index].end = at(690)
        p.publication!.state = .needsConfirmation
        let result = CalendarSchedule.reconciling(p, times: [.init(id: event.id, start: at(840), end: at(870))], settings: settings)
        XCTAssertEqual(result.conflicts, [event.title])
        XCTAssertEqual(result.plan.blocks[index].start, at(660))
        XCTAssertEqual(result.plan.publication!.desired.first { $0.id == event.id }?.start, at(840))
        XCTAssertEqual(result.plan.publication!.state, .needsConfirmation)
        XCTAssertTrue(result.plan.publication!.lastError != nil)
    }
    func testPendingPreflightDistinguishesLocalMovesRemoteMovesAndConflicts() {
        let old = published(), event = old.publication!.desired.first { $0.taskID != nil }!
        var local = old
        let index = local.blocks.firstIndex { $0.id == event.blockID }!
        local.blocks[index].start = at(660); local.blocks[index].end = at(690)
        local.publication = CalendarPublication(plan: local, workspaceID: workspace, destination: old.publication!.destination, timeZone: settings.timeZone)
        let baselineRead = [CalendarEventTime(id: event.id, start: event.start, end: event.end)]
        XCTAssertEqual(CalendarSchedule.reconciling(local, times: baselineRead, settings: settings, includingPending: true).plan, local)
        let remoteRead = [CalendarEventTime(id: event.id, start: at(840), end: at(870))]
        XCTAssertEqual(CalendarSchedule.reconciling(local, times: remoteRead, settings: settings).plan, local)
        let conflict = CalendarSchedule.reconciling(local, times: remoteRead, settings: settings, includingPending: true)
        XCTAssertEqual(conflict.conflicts.count, 1); XCTAssertEqual(conflict.plan.publication!.state, .needsConfirmation)
        var retry = old
        retry.publication = CalendarPublication(plan: old, workspaceID: workspace, destination: old.publication!.destination, timeZone: settings.timeZone)
        let imported = CalendarSchedule.reconciling(retry, times: remoteRead, settings: settings, includingPending: true)
        XCTAssertTrue(imported.conflicts.isEmpty)
        XCTAssertEqual(imported.plan.blocks.first { $0.taskID != nil }?.start, at(840))
        XCTAssertEqual(imported.plan.publication!.state, .pending)
        XCTAssertTrue(imported.plan.publication!.matches(imported.plan, timeZone: settings.timeZone))
    }
    func testScheduleEntriesDistinguishDraftPendingAndBookedAndExcludeClosedWork() {
        var p = published()
        let now = at(480), publishedEntries = TaskScheduleEntry.entries(taskID: task.id, plans: [p], now: now)
        XCTAssertEqual(publishedEntries.count, 1); XCTAssertEqual(publishedEntries[0].status, .calendar)
        var draft = p; draft.publication = nil
        XCTAssertEqual(TaskScheduleEntry.entries(taskID: task.id, plans: [draft], now: now).first?.status, .draft)
        p.publication!.state = .pending
        XCTAssertEqual(TaskScheduleEntry.entries(taskID: task.id, plans: [p], now: now).first?.status, .pending)
        XCTAssertTrue(TaskScheduleEntry.entries(taskID: "absent", plans: [p], now: now).isEmpty)
        p.blocks[p.blocks.firstIndex { $0.taskID != nil }!].state = .completed
        XCTAssertTrue(TaskScheduleEntry.entries(taskID: task.id, plans: [p], now: now).isEmpty)
        XCTAssertTrue(TaskScheduleEntry.entries(taskID: task.id, plans: [draft], now: at(1020)).isEmpty)
    }
    func testImportedTimesAndBaselineSurviveRepositoryRestart() throws {
        let p = published(), event = p.publication!.desired.first { $0.taskID != nil }!
        let moved = CalendarSchedule.reconciling(p, times: [.init(id: event.id, start: at(840), end: at(870))], settings: settings).plan
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = try DataRepository(root: root.appendingPathComponent("Data"), localState: root.appendingPathComponent("Local"))
        try repo.save(plan: moved, message: "Import calendar times")
        let loaded = try repo.load(DayPlan.self, directory: "plans").first!
        XCTAssertEqual(loaded, moved)
        XCTAssertTrue(loaded.publication!.matches(loaded, timeZone: settings.timeZone))
    }
    func testMissingCalendarEventsKeepLastTimesWithoutClaimingTheyAreBooked() {
        var p = published()
        let event = p.publication!.desired.first { $0.taskID != nil }!
        p.publication!.missingEventIDs = [event.id]
        let entries = TaskScheduleEntry.entries(taskID: task.id, plans: [p], now: at(480))
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].status, .unavailable)
        XCTAssertEqual(entries[0].start, event.start)
        XCTAssertEqual(CalendarSchedule.reconciling(p, times: [], settings: settings).plan, p)
        p.publication!.state = .pending
        XCTAssertEqual(TaskScheduleEntry.entries(taskID: task.id, plans: [p], now: at(480)).first?.status, .pending)
    }
}
