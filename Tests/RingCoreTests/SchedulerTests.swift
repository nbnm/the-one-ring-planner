import Foundation
import RingCore

final class SchedulerTests {
    var settings = PlanningSettings()
    var day: Date { ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")! }
    var early: Date { PlannerDate.at(480, on: day, settings: settings) }
    func at(_ n: Int) -> Date { PlannerDate.at(n, on: day, settings: settings) }
    func task(_ id: String, minutes: Int, q: Quadrant = .schedule) -> PlannerTask {
        var t = PlannerTask(id: id, title: id, state: .ready, importance: q == .doFirst || q == .schedule, urgency: q == .doFirst || q == .delegate, remainingMinutes: minutes, now: early)
        t.minimumBlockMinutes = min(25, minutes); return t
    }
    func testDeterministicAndNoOvertimeOrOverlaps() {
        let tasks = (0..<10).map { task("task-\($0)", minutes: 90) }
        let a = Scheduler().makePlan(day: day, now: early, tasks: tasks, routines: [], settings: settings)
        let b = Scheduler().makePlan(day: day, now: early, tasks: tasks.reversed(), routines: [], settings: settings)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.unscheduled.isEmpty)
        for block in a.blocks { XCTAssertGreaterThanOrEqual(block.start, at(540)); XCTAssertLessThanOrEqual(block.end, at(1020)) }
        for (first, next) in zip(a.blocks, a.blocks.dropFirst()) { XCTAssertLessThanOrEqual(first.end, next.start) }
        XCTAssertGreaterThanOrEqual(a.freeMinutes, a.reserveMinutes)
    }
    func testPriorityOutcomesWaitingAndQ4() {
        var waiting = task("waiting", minutes: 30); waiting.state = .waiting
        let tasks = [task("q4", minutes: 30, q: .reconsider), waiting, task("q2", minutes: 90), task("q1", minutes: 90, q: .doFirst)]
        let p = Scheduler().makePlan(day: day, now: early, tasks: tasks, routines: [], settings: settings, outcomeIDs: ["q2"])
        let focus = p.blocks.filter { $0.kind == .focus }
        XCTAssertEqual(focus.first?.taskID, "q1")
        XCTAssertEqual(focus.filter { $0.taskID == "q2" }.reduce(0) { $0 + $1.minutes }, 90)
        XCTAssertFalse(focus.contains { $0.taskID == "q4" || $0.taskID == "waiting" })
    }
    func testTransitionMustFitRealCapacity() {
        settings.workEnd = 600; settings.lunchStart = 540; settings.lunchMinutes = 0; settings.reservePercent = 0
        var t = task("work", minutes: 50); t.allowsSplitting = false
        let meeting = PlanBlock(id: "meeting", title: "Fixed", kind: .meeting, start: at(595), end: at(600))
        let p = Scheduler().makePlan(day: day, now: early, tasks: [t], routines: [], settings: settings, meetings: [meeting])
        XCTAssertEqual(p.blocks.first { $0.taskID == t.id }?.minutes, 50)
        XCTAssertEqual(p.blocks.first { $0.kind == .transition }?.minutes, 5)
        XCTAssertEqual(p.blocks.last?.id, meeting.id)
        t.remainingMinutes = 55
        let tooLong = Scheduler().makePlan(day: day, now: early, tasks: [t], routines: [], settings: settings, meetings: [meeting])
        XCTAssertFalse(tooLong.blocks.contains { $0.taskID == t.id })
    }
    func testTouchingMeetingsArePreservedAndReportMissingGap() {
        let one = PlanBlock(id: "one", title: "One", kind: .meeting, start: at(600), end: at(660))
        let two = PlanBlock(id: "two", title: "Two", kind: .meeting, start: at(660), end: at(690))
        let p = Scheduler().makePlan(day: day, now: early, tasks: [], routines: [], settings: settings, meetings: [one, two])
        XCTAssertEqual(p.blocks.first { $0.id == "one" }, one)
        XCTAssertEqual(p.blocks.first { $0.id == "two" }, two)
        XCTAssertTrue(p.warnings.contains { $0.contains("Missing 10-minute") })
        XCTAssertFalse(p.blocks.contains { $0.kind == .transition && $0.start == at(660) })
        XCTAssertTrue(p.blocks.contains { $0.kind == .transition && $0.start == at(690) && $0.minutes == 10 })
    }
    func testSharedGapIsMaxNotSum() {
        let one = PlanBlock(id: "one", title: "One", kind: .meeting, start: at(600), end: at(660))
        let two = PlanBlock(id: "two", title: "Two", kind: .meeting, start: at(670), end: at(700))
        let p = Scheduler().makePlan(day: day, now: early, tasks: [], routines: [], settings: settings, meetings: [one, two])
        XCTAssertTrue(p.warnings.isEmpty)
        let gap = p.blocks.filter { $0.kind == .transition && $0.start >= at(660) && $0.end <= at(670) }
        XCTAssertEqual(gap.count, 1); XCTAssertEqual(gap.first?.minutes, 10)
    }
    func testPinsRemainAndRemainingEffortSchedulesOnce() {
        let t = task("one", minutes: 60)
        let original = Scheduler().makePlan(day: day, now: early, tasks: [t], routines: [], settings: settings)
        var prior = original
        let index = prior.blocks.firstIndex { $0.taskID == "one" }!
        prior.blocks[index].pinned = true
        let pinned = prior.blocks[index]
        let p = Scheduler().makePlan(day: day, now: early, tasks: [t], routines: [], settings: settings, previous: prior)
        XCTAssertTrue(p.blocks.contains(pinned))
        XCTAssertEqual(p.blocks.filter { $0.taskID == "one" }.reduce(0) { $0 + $1.minutes }, 60)
        XCTAssertEqual(Set(p.blocks.map(\.id)).count, p.blocks.count)
    }
    func testDependencyAndDeadlineRisk() {
        var dependent = task("dependent", minutes: 30); dependent.dependencies = ["missing"]
        var late = task("late", minutes: 90, q: .doFirst); late.deadline = at(570)
        let p = Scheduler().makePlan(day: day, now: early, tasks: [dependent, late], routines: [], settings: settings)
        XCTAssertFalse(p.blocks.contains { $0.taskID == "dependent" })
        XCTAssertTrue(p.unscheduled.contains { $0.id == "late" && $0.reason.contains("Deadline at risk") })
    }
    func testProtectedRoutineSurvivesReplanAndFlexibleCanOverflow() {
        let protected = Routine(id: "guitar", title: "Guitar", kind: .guitar, minutes: 10, startMinute: 840, endMinute: 900, protected: true, enabled: true)
        let old = Scheduler().makePlan(day: day, now: early, tasks: [], routines: [protected], settings: settings)
        let block = old.blocks.first { $0.routineID == protected.id }!
        let p = Scheduler().makePlan(day: day, now: early, tasks: [task("urgent", minutes: 300, q: .doFirst)], routines: [protected], settings: settings, previous: old)
        XCTAssertTrue(p.blocks.contains(block))
    }
    func testLocalCalendarUsesTorontoAcrossDST() {
        let dates = ["2026-03-08T12:00:00Z", "2026-11-01T12:00:00Z"]
        for value in dates {
            let d = ISO8601DateFormatter().date(from: value)!
            let nine = PlannerDate.at(540, on: d, settings: settings)
            XCTAssertEqual(PlannerDate.calendar(settings).component(.hour, from: nine), 9)
        }
    }
}
