import Foundation
import RingCore

final class TaskSlotTests {
    var settings = PlanningSettings()
    let day = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
    func at(_ minute: Int) -> Date { PlannerDate.at(minute, on: day, settings: settings) }
    func task(_ id: String = "q2", minutes: Int = 60) -> PlannerTask { PlannerTask(id: id, title: id, context: "T1A", state: .ready, importance: true, urgency: false, remainingMinutes: minutes) }
    func testSuggestionsRespectCalendarLunchExistingWorkAndAlternatives() {
        let target = task(), other = task("existing")
        let meeting = PlanBlock(id: "meeting", title: "Meeting", kind: .meeting, start: at(540), end: at(600))
        var existing = Scheduler().makePlan(day: day, now: at(480), tasks: [other], routines: [], settings: settings, meetings: [meeting])
        let focus = existing.blocks.filter { $0.kind == .focus }
        let options = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [meeting], previous: existing, notBeforeMinute: 540)
        XCTAssertFalse(options.isEmpty)
        for option in options {
            XCTAssertTrue(option.start >= meeting.end)
            XCTAssertFalse(focus.contains { $0.start < option.end && $0.end > option.start })
            XCTAssertFalse(option.start < at(780) && option.end > at(720))
        }
        let rejected = Set(options.map(\.id))
        let alternate = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [meeting], previous: existing, notBeforeMinute: 540, excluding: rejected)
        XCTAssertTrue(alternate.allSatisfy { !rejected.contains($0.id) })
        let original = existing
        existing = TaskSlotPlanner.accepting(options[0], task: target, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [meeting], previous: existing)
        XCTAssertEqual(existing.blocks.filter { $0.taskID == other.id }, focus)
        XCTAssertTrue(existing.blocks.contains { $0.taskID == target.id && $0.start == options[0].start && $0.pinned })
        XCTAssertEqual(existing.previousBlocks, original.blocks)
    }
    func testSuggestionsHonorDeadlinePrerequisitesReserveAndLocalTime() {
        var target = task(); target.dependencies = ["missing"]
        XCTAssertTrue(TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target], routines: [], settings: settings, meetings: [], previous: nil, notBeforeMinute: 540).isEmpty)
        target = task(); target.deadline = at(570)
        XCTAssertTrue(TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target], routines: [], settings: settings, meetings: [], previous: nil, notBeforeMinute: 540).isEmpty)
        target = task(); target.earliestStart = at(840)
        let options = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(800), tasks: [target], routines: [], settings: settings, meetings: [], previous: nil, notBeforeMinute: 810)
        XCTAssertTrue(options.allSatisfy { $0.start >= at(840) && $0.end <= at(1020) })
        settings.workEnd = 600; settings.lunchMinutes = 0; settings.reservePercent = 50
        target = task()
        XCTAssertTrue(TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target], routines: [], settings: settings, meetings: [], previous: nil, notBeforeMinute: 540).isEmpty)
    }
    func testAcceptingOneSlotDoesNotPublishOtherDraftTasks() {
        let target = task(), other = task("draft")
        let previous = Scheduler().makePlan(day: day, now: at(480), tasks: [other], routines: [], settings: settings)
        let option = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: previous, notBeforeMinute: 540)[0]
        let accepted = TaskSlotPlanner.accepting(option, task: target, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: previous)
        let added = accepted.blocks.first { $0.taskID == target.id }!
        let publication = CalendarPublication(plan: accepted, workspaceID: "workspace", destination: PublicationDestination(id: "work", title: "Work", accountID: "owner"), timeZone: settings.timeZone, confirmedBlockIDs: [added.id])
        XCTAssertEqual(publication.desired.count, 1)
        XCTAssertEqual(publication.desired[0].taskID, target.id)
        XCTAssertTrue(publication.matches(accepted, timeZone: settings.timeZone))
        XCTAssertTrue(accepted.blocks.contains { $0.taskID == other.id })
    }
    func testScopeSurvivesRestartAndFullConfirmationIncludesRemainingWork() throws {
        let target = task(), other = task("other")
        var p = Scheduler().makePlan(day: day, now: at(480), tasks: [target, other], routines: [], settings: settings)
        let block = p.blocks.first { $0.taskID == target.id }!
        p.publication = CalendarPublication(plan: p, workspaceID: "workspace", destination: PublicationDestination(id: "work", title: "Work", accountID: "owner"), timeZone: settings.timeZone, confirmedBlockIDs: [block.id])
        let data = try JSONEncoder().encode(p), loaded = try JSONDecoder().decode(DayPlan.self, from: data)
        XCTAssertEqual(loaded.publication, p.publication)
        let full = CalendarPublication(plan: loaded, workspaceID: "workspace", destination: loaded.publication!.destination, timeZone: settings.timeZone)
        XCTAssertTrue(full.desired.contains { $0.taskID == other.id })
        XCTAssertTrue(full.known.contains { $0.id == loaded.publication!.desired[0].id })
    }
    func testNewSlotDoesNotRemovePreviouslyConfirmedClosedWork() {
        let target = task(), other = task("other")
        var p = Scheduler().makePlan(day: day, now: at(480), tasks: [other], routines: [], settings: settings)
        let destination = PublicationDestination(id: "work", title: "Work", accountID: "owner")
        p.publication = CalendarPublication(plan: p, workspaceID: "workspace", destination: destination, timeZone: settings.timeZone)
        let original = p.publication!.desired
        for i in p.blocks.indices where p.blocks[i].kind == .focus { p.blocks[i].state = .interrupted }
        let proposal = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: p, notBeforeMinute: 540)[0]
        let accepted = TaskSlotPlanner.accepting(proposal, task: target, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: p)
        let added = accepted.blocks.first { $0.taskID == target.id }!
        let publication = CalendarPublication(plan: accepted, workspaceID: "workspace", destination: destination, timeZone: settings.timeZone, confirmedBlockIDs: [added.id], keepingExistingEvents: true)
        XCTAssertTrue(original.allSatisfy { publication.desired.contains($0) })
        XCTAssertEqual(publication.desired.filter { $0.taskID == target.id }.count, 1)
        XCTAssertTrue(publication.matches(accepted, timeZone: settings.timeZone))
    }
}

extension TaskSlotTests {
    func testTodaySearchAndClosedDraftsDoNotHideCurrentWeekGaps() {
        XCTAssertEqual(TaskSlotPlanner.searchStart(now: at(800), settings: settings), PlannerDate.calendar(settings).startOfDay(for: day))
        let target = task(), old = task("closed")
        var previous = Scheduler().makePlan(day: day, now: at(480), tasks: [], routines: [], settings: settings)
        previous.blocks = [PlanBlock(id: "old-meeting", title: "Removed meeting", kind: .meeting, start: at(540), end: at(720)),
            PlanBlock(id: "closed", title: "Completed earlier", kind: .focus, start: at(540), end: at(720), taskID: old.id, pinned: true, state: .completed)]
        let options = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, old], routines: [], settings: settings, meetings: [], previous: previous, notBeforeMinute: 540, reserveIsHardLimit: false)
        XCTAssertEqual(options.first?.start, at(540))
    }
    func testExplicitBookingUsesReserveWithAVisibleWarning() {
        settings.workEnd = 660; settings.lunchMinutes = 0; settings.reservePercent = 50
        let target = task(minutes: 30), existing = task("existing")
        var previous = Scheduler().makePlan(day: day, now: at(480), tasks: [], routines: [], settings: settings)
        previous.blocks = [PlanBlock(id: "booked", title: "Existing task", kind: .focus, start: at(540), end: at(600), taskID: existing.id, pinned: true)]
        let strict = TaskSlotPlanner.suggestions(task: target, minutes: 30, day: day, now: at(480), tasks: [target, existing], routines: [], settings: settings, meetings: [], previous: previous, notBeforeMinute: 540)
        XCTAssertTrue(strict.isEmpty)
        let available = TaskSlotPlanner.suggestions(task: target, minutes: 30, day: day, now: at(480), tasks: [target, existing], routines: [], settings: settings, meetings: [], previous: previous, notBeforeMinute: 540, reserveIsHardLimit: false)
        XCTAssertEqual(available.first?.start, at(605))
        let assessment = TaskSlotPlanner.assessment(available[0], task: target, now: at(480), tasks: [target, existing], routines: [], settings: settings, meetings: [], previous: previous)
        XCTAssertTrue(assessment.canBook); XCTAssertTrue(assessment.warnings.contains { $0.contains("reserve") })
    }
    func testManualCalendarChoiceValidatesOverlapAndExplainsPreferences() {
        let target = task(), meeting = PlanBlock(id: "meeting", title: "Real call", kind: .meeting, start: at(600), end: at(660))
        func assess(_ start: Int, _ end: Int) -> TaskSlotAssessment {
            TaskSlotPlanner.assessment(TaskTimeSlot(taskID: target.id, start: at(start), end: at(end)), task: target, now: at(420), tasks: [target], routines: [], settings: settings, meetings: [meeting], previous: nil)
        }
        XCTAssertFalse(assess(570, 630).canBook)
        XCTAssertTrue(assess(540, 600).canBook)
        XCTAssertTrue(assess(540, 600).warnings.contains { $0.contains("transition") })
        XCTAssertTrue(assess(480, 540).canBook)
        XCTAssertTrue(assess(480, 540).warnings.contains { $0.contains("work hours") })
        var restricted = target; restricted.earliestStart = at(660)
        let blocked = TaskSlotPlanner.assessment(TaskTimeSlot(taskID: target.id, start: at(540), end: at(600)), task: restricted, now: at(420), tasks: [restricted], routines: [], settings: settings, meetings: [], previous: nil)
        XCTAssertFalse(blocked.canBook)
    }
    func testOwnedCalendarEventsAndMissingOldBookingsUseActualAvailability() {
        let target = task(), other = task("other")
        var p = Scheduler().makePlan(day: day, now: at(480), tasks: [], routines: [], settings: settings)
        p.blocks = [PlanBlock(id: "missing", title: "Deleted old booking", kind: .focus, start: at(540), end: at(600), taskID: other.id, pinned: true)]
        p.publication = CalendarPublication(plan: p, workspaceID: "workspace", destination: .init(id: "work", title: "Work", accountID: "owner"), timeZone: settings.timeZone)
        p.publication!.missingEventIDs = p.publication!.desired.map(\.id)
        let free = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: p, notBeforeMinute: 540, reserveIsHardLimit: false)
        XCTAssertEqual(free.first?.start, at(540))
        let actual = PlanBlock(id: "actual", title: "Planner event with no local block", kind: .focus, start: at(540), end: at(600))
        let owned = TaskSlotPlanner.suggestions(task: target, minutes: 60, day: day, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: p, notBeforeMinute: 540, reserveIsHardLimit: false, calendarBusy: [actual])
        XCTAssertEqual(owned.first?.start, at(605))
        XCTAssertTrue(TaskSlotPlanner.accepting(free[0], task: target, now: at(480), tasks: [target, other], routines: [], settings: settings, meetings: [], previous: p).blocks.contains { $0.taskID == target.id })
    }
}


extension TaskSlotTests {
    func testSplittableTaskUsesEarlierGapsWithoutTinyRemainders() {
        var target = task(minutes: 60); target.minimumBlockMinutes = 25
        let lengths = TaskSlotPlanner.candidateLengths(task: target, minutes: 60, focusMinutes: 50, automaticFit: true)
        XCTAssertEqual(lengths, [60, 35, 30, 25])
        let meeting = PlanBlock(id: "later", title: "Calendar", kind: .meeting, start: at(575), end: at(1020))
        var choices: [TaskTimeSlot] = []
        for amount in lengths {
            let found = TaskSlotPlanner.suggestions(task: target, minutes: amount, day: day, now: at(480), tasks: [target], routines: [], settings: settings, meetings: [meeting], previous: nil, notBeforeMinute: 540, reserveIsHardLimit: false)
            choices.append(contentsOf: found)
        }
        choices.sort { $0.start == $1.start ? $0.minutes > $1.minutes : $0.start < $1.start }
        XCTAssertEqual(choices.first?.start, at(540)); XCTAssertEqual(choices.first?.minutes, 30)
        target.allowsSplitting = false
        XCTAssertEqual(TaskSlotPlanner.candidateLengths(task: target, minutes: 60, focusMinutes: 50, automaticFit: true), [60])
    }
}
