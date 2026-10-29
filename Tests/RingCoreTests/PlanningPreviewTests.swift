import Foundation
import RingCore

final class PlanningPreviewTests {
    var settings = PlanningSettings()
    let day = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
    func at(_ minute: Int) -> Date { PlannerDate.at(minute, on: day, settings: settings) }
    func task(_ id: String, minutes: Int) -> PlannerTask {
        PlannerTask(id: id, title: id, state: .ready, importance: true, urgency: false, remainingMinutes: minutes, now: at(480))
    }
    func meeting(_ id: String, from: Int, until: Int) -> PlanBlock {
        PlanBlock(id: id, title: id, kind: .meeting, start: at(from), end: at(until))
    }
    func noGaps() {
        settings.relatedTransition = 0; settings.projectTransition = 0
        settings.meetingPreparation = 0; settings.meetingRecovery = 0
    }
    func testAvailableTimeAccountsForCalendarActivitiesTransitionsAndReserve() {
        let tasks = [task("work", minutes: 90)]
        let routines = [Routine(id: "walk", title: "Walk", minutes: 30, startMinute: 900, endMinute: 960, protected: true, enabled: true)]
        let meetings = [meeting("meeting", from: 600, until: 660)]
        let preview = Scheduler().preview(day: day, now: at(480), tasks: tasks, routines: routines, settings: settings, meetings: meetings)
        XCTAssertEqual(preview.workMinutes, 480)
        XCTAssertEqual(preview.calendarMinutes, 60)
        XCTAssertEqual(preview.lunchMinutes, 60)
        XCTAssertEqual(preview.routineMinutes, 30)
        XCTAssertEqual(preview.transitionMinutes, 20)
        XCTAssertEqual(preview.reserveMinutes, 65)
        XCTAssertEqual(preview.availableMinutes, 245)
        XCTAssertEqual(preview.selectedEffortMinutes, 90)
        XCTAssertEqual(preview.scheduledEffortMinutes, 90)
        XCTAssertEqual(preview.proposedPlan, Scheduler().makePlan(day: day, now: at(480), tasks: tasks, routines: routines, settings: settings, meetings: meetings))
    }
    func testOverlappingCalendarAndLunchUseUnionInsideWorkday() {
        noGaps(); settings.reservePercent = 0; settings.lunchStart = 600
        let meetings = [meeting("one", from: 480, until: 600), meeting("two", from: 570, until: 630), meeting("outside", from: 1080, until: 1140)]
        let preview = Scheduler().preview(day: day, now: at(480), tasks: [], routines: [], settings: settings, meetings: meetings)
        XCTAssertEqual(preview.calendarMinutes, 90)
        XCTAssertEqual(preview.lunchMinutes, 30)
        XCTAssertEqual(preview.availableMinutes, 360)
        XCTAssertFalse(preview.proposedPlan.warnings.isEmpty)
        XCTAssertEqual(preview.calendarMinutes + preview.lunchMinutes + preview.availableMinutes, preview.workMinutes)
    }
    func testExistingPinnedWorkConsumesCapacityUntilDeselected() {
        noGaps(); settings.reservePercent = 0; settings.lunchMinutes = 0
        let tasks = [task("pinned", minutes: 60)]
        var prior = Scheduler().makePlan(day: day, now: at(480), tasks: tasks, routines: [], settings: settings)
        for i in prior.blocks.indices where prior.blocks[i].kind == .focus { prior.blocks[i].pinned = true }
        let selected = Scheduler().preview(day: day, now: at(480), tasks: tasks, routines: [], settings: settings, previous: prior, selectedTaskIDs: ["pinned"])
        XCTAssertEqual(selected.committedTaskMinutes, 60)
        XCTAssertEqual(selected.availableMinutes, 420)
        XCTAssertEqual(selected.scheduledEffortMinutes, 60)
        let removed = Scheduler().preview(day: day, now: at(480), tasks: tasks, routines: [], settings: settings, previous: prior, selectedTaskIDs: [])
        XCTAssertEqual(removed.committedTaskMinutes, 0)
        XCTAssertEqual(removed.availableMinutes, 480)
        XCTAssertEqual(removed.selectedEffortMinutes, 0)
    }
    func testRemainingTodayAndPastOrFullDaysNeverOverstateTime() {
        noGaps(); settings.reservePercent = 0
        let routines = [Routine(id: "read", title: "Read", minutes: 15, startMinute: 900, endMinute: 960, enabled: true)]
        let preview = Scheduler().preview(day: day, now: at(722), tasks: [], routines: routines, settings: settings,
                                          meetings: [meeting("past", from: 540, until: 600), meeting("future", from: 840, until: 900)])
        XCTAssertEqual(preview.elapsedMinutes, 185)
        XCTAssertEqual(preview.calendarMinutes, 60)
        XCTAssertEqual(preview.lunchMinutes, 55)
        XCTAssertEqual(preview.routineMinutes, 15)
        XCTAssertEqual(preview.availableMinutes, 165)
        let tomorrow = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        let past = Scheduler().preview(day: day, now: tomorrow, tasks: [], routines: [], settings: settings)
        XCTAssertEqual(past.availableMinutes, 0)
        let full = Scheduler().preview(day: day, now: at(480), tasks: [], routines: [], settings: settings, meetings: [meeting("busy", from: 540, until: 1020)])
        XCTAssertEqual(full.availableMinutes, 0)
        XCTAssertEqual(full.lunchMinutes, 0)
    }
    func testFitHonorsOverflowDependenciesAndTaskWindows() {
        noGaps(); settings.reservePercent = 0
        let overflow = Scheduler().preview(day: day, now: at(480), tasks: [task("one", minutes: 300), task("two", minutes: 300)], routines: [], settings: settings)
        XCTAssertEqual(overflow.availableMinutes, 420)
        XCTAssertEqual(overflow.selectedEffortMinutes, 600)
        XCTAssertEqual(overflow.scheduledEffortMinutes, 420)
        XCTAssertEqual(overflow.unscheduledTasks.reduce(0) { $0 + $1.minutes }, 180)
        var dependent = task("dependent", minutes: 60); dependent.dependencies = ["missing"]
        var urgent = task("too-late", minutes: 30); urgent.deadline = at(550)
        let blocked = Scheduler().preview(day: day, now: at(480), tasks: [dependent, urgent], routines: [], settings: settings)
        XCTAssertEqual(blocked.availableMinutes, 420)
        XCTAssertEqual(blocked.scheduledEffortMinutes, 0)
        XCTAssertEqual(blocked.unscheduledTasks.count, 2)
    }
    func testFlexibleActivitiesAndRecurrenceAreExplainedByActualDraft() {
        noGaps(); settings.reservePercent = 0; settings.lunchMinutes = 0; settings.workEnd = 600
        let due = Routine(id: "due", title: "Read", minutes: 30, startMinute: 540, endMinute: 600, enabled: true, weekdays: [.tuesday])
        let offDay = Routine(id: "off", title: "Walk", minutes: 15, startMinute: 540, endMinute: 600, enabled: true, weekdays: [.wednesday])
        let tasks = [task("work", minutes: 60)]
        let preview = Scheduler().preview(day: day, now: at(480), tasks: tasks, routines: [due, offDay], settings: settings)
        XCTAssertEqual(preview.routineMinutes, 30)
        XCTAssertEqual(preview.availableMinutes, 30)
        XCTAssertEqual(preview.scheduledEffortMinutes, 60)
        XCTAssertTrue(preview.proposedPlan.unscheduled.contains { $0.id == due.id })
        XCTAssertFalse(preview.proposedPlan.unscheduled.contains { $0.id == offDay.id })
        let empty = Scheduler().preview(day: day, now: at(480), tasks: tasks, routines: [due, offDay], settings: settings, selectedTaskIDs: [])
        XCTAssertEqual(empty.selectedEffortMinutes, 0)
        XCTAssertEqual(empty.scheduledEffortMinutes, 0)
        XCTAssertTrue(empty.proposedPlan.blocks.contains { $0.routineID == due.id })
    }
}
