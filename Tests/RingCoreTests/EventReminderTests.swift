import Foundation
import RingCore

struct EventReminderTests {
    let fixture = CalendarScheduleTests()
    var now: Date { fixture.at(480) }
    func occurrence(_ id: String = "meeting", start: Date? = nil, allDay: Bool = false, calendarID: String = "work") -> CalendarOccurrence {
        let date = start ?? fixture.at(600)
        return CalendarOccurrence(id: id, calendarID: calendarID, title: "8FDE planning", calendarTitle: "T1A", start: date, end: date.addingTimeInterval(1800), allDay: allDay)
    }
    func owned(_ event: CalendarPlanEvent, plan: DayPlan, start: Date? = nil) -> CalendarOccurrence {
        let date = start ?? event.start
        return CalendarOccurrence(id: event.id, calendarID: "work", title: event.title, calendarTitle: "T1A", start: date, end: date.addingTimeInterval(1800), managedByPlanner: true, plannerCategory: event.category, plannerTaskID: event.taskID, plannerRoutineID: event.routineID, plannerBlockID: event.blockID, plannerDay: plan.id)
    }
    func testExactLeadTimeAndPastAllDayFiltering() {
        let event = occurrence(), near = occurrence("near", start: now.addingTimeInterval(59)), past = occurrence("past", start: now.addingTimeInterval(-1))
        let reminders = EventReminderPlanner.reminders(events: [event, near, past, occurrence("all-day", allDay: true), event], plans: [], tasks: [], now: now)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.fireDate, event.start.addingTimeInterval(-60))
        XCTAssertEqual(reminders.first?.kind, "Calendar event")
        XCTAssertTrue(EventReminderPlanner.reminders(events: [event], plans: [], tasks: [], now: event.start).isEmpty)
    }
    func testMovedEventReplacesReminderAndCalendarsHaveIndependentIdentity() {
        let event = occurrence(), moved = occurrence(start: fixture.at(720))
        let before = EventReminderPlanner.reminders(events: [event], plans: [], tasks: [], now: now).first!
        let after = EventReminderPlanner.reminders(events: [moved], plans: [], tasks: [], now: now).first!
        XCTAssertEqual(before.id, after.id); XCTAssertEqual(after.start, fixture.at(720))
        XCTAssertFalse(before == after)
        let distinct = EventReminderPlanner.reminders(events: [event, occurrence(calendarID: "personal")], plans: [], tasks: [], now: now)
        XCTAssertEqual(distinct.count, 2); XCTAssertFalse(distinct[0].id == distinct[1].id)
    }
    func testPublishedMirrorsDoNotDuplicateAndDeletedEventsDoNotReturn() {
        let plan = fixture.published(), event = plan.publication!.desired.first { $0.taskID != nil }!
        let actual = owned(event, plan: plan, start: fixture.at(900))
        let reminders = EventReminderPlanner.reminders(events: [actual], plans: [plan], tasks: [fixture.task], now: now)
        XCTAssertEqual(reminders.count, 1); XCTAssertEqual(reminders.first?.start, fixture.at(900))
        XCTAssertEqual(reminders.first?.kind, "Task")
        XCTAssertTrue(EventReminderPlanner.reminders(events: [], plans: [plan], tasks: [fixture.task], now: now).isEmpty)
    }
    func testCompletedTasksAndClosedRoutineOccurrencesAreSilent() {
        var plan = fixture.published(), task = fixture.task
        task.state = .done
        let taskEvent = plan.publication!.desired.first { $0.taskID != nil }!, routine = plan.publication!.desired.first { $0.routineID != nil }!
        let events = [owned(taskEvent, plan: plan), owned(routine, plan: plan)]
        XCTAssertEqual(EventReminderPlanner.reminders(events: events, plans: [plan], tasks: [task], now: now).map(\.kind), ["Routine"])
        plan.blocks[plan.blocks.firstIndex { $0.routineID != nil }!].state = .skipped
        XCTAssertTrue(EventReminderPlanner.reminders(events: events, plans: [plan], tasks: [task], now: now).isEmpty)
        task.state = .inbox
        XCTAssertTrue(EventReminderPlanner.reminders(events: events, plans: [plan], tasks: [task], now: now).isEmpty)
    }
    func testOnlyConfirmedLocalWorkAlertsAndUnrelatedDraftsStaySilent() {
        var plan = fixture.published(); plan.publication = nil
        let reminders = EventReminderPlanner.reminders(events: [], plans: [plan], tasks: [fixture.task], now: now)
        XCTAssertEqual(reminders.count, 2); XCTAssertEqual(Set(reminders.map(\.kind)), ["Task", "Routine"])
        plan.status = .draft
        XCTAssertTrue(EventReminderPlanner.reminders(events: [], plans: [plan], tasks: [fixture.task], now: now).isEmpty)
    }
    func testRollingLimitKeepsNearestEvents() {
        let events = (0..<80).reversed().map { occurrence("call-\($0)", start: now.addingTimeInterval(Double(120 + $0 * 60))) }
        let reminders = EventReminderPlanner.reminders(events: events, plans: [], tasks: [], now: now)
        XCTAssertEqual(reminders.count, 60); XCTAssertEqual(reminders.first?.start, now.addingTimeInterval(120))
        XCTAssertEqual(reminders.last?.start, now.addingTimeInterval(120 + 59 * 60))
    }
}
