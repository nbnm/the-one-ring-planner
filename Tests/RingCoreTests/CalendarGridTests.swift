import Foundation
import RingCore

struct CalendarGridTests {
    let settings = PlanningSettings()
    var calendar: Calendar { PlannerDate.calendar(settings) }
    var day: Date { ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")! }
    func date(_ minute: Int, day: Date? = nil) -> Date { PlannerDate.at(minute, on: day ?? self.day, settings: settings) }
    func event(_ id: String, _ start: Int, _ end: Int, busy: Bool = true) -> CalendarGridEvent { CalendarGridEvent(id: id, title: id, start: date(start), end: date(end), busy: busy, category: .task) }
    func testHeightsAreProportionalToDuration() {
        let events = [event("half-hour", 540, 570), event("hour", 600, 660), event("ninety-minutes", 720, 810), event("five-minutes", 900, 905)]
        let placements = CalendarGrid.placements(on: day, events: events, calendar: calendar)
        XCTAssertEqual(placements.map(\.duration), [30, 60, 90, 5])
        XCTAssertEqual(placements[1].duration, placements[0].duration * 2)
        XCTAssertTrue(placements.allSatisfy { $0.laneCount == 1 })
        XCTAssertEqual(placements[0].startMinute, 540)
    }
    func testOverlapGroupsUseStableNonCollidingLanes() {
        let values = [event("A", 540, 600), event("B", 570, 630), event("C", 600, 660), event("D", 660, 690), event("E", 575, 590)]
        let placements = CalendarGrid.placements(on: day, events: values, calendar: calendar)
        let group = placements.filter { $0.event.id != "D" }
        XCTAssertTrue(group.allSatisfy { $0.laneCount == 3 })
        XCTAssertEqual(placements.first { $0.id == "D" }?.laneCount, 1)
        XCTAssertEqual(placements.first { $0.id == "A" }?.lane, placements.first { $0.id == "C" }?.lane)
        for a in placements { for b in placements where a.id != b.id && a.event.start < b.event.end && b.event.start < a.event.end { XCTAssertTrue(a.lane != b.lane) } }
        XCTAssertEqual(CalendarGrid.placements(on: day, events: values.reversed(), calendar: calendar), placements)
    }
    func testPublishedBlocksDeduplicateByIdentityAtGoogleTimes() {
        let task = PlannerTask(id: "published", title: "Same title", state: .ready, importance: true, urgency: false, remainingMinutes: 60)
        var plan = Scheduler().makePlan(day: day, now: date(480), tasks: [task], routines: [], settings: settings)
        plan.blocks = [PlanBlock(id: "published-block", title: task.title, kind: .focus, start: date(540), end: date(600), taskID: task.id)]
        let block = plan.blocks.first { $0.taskID == task.id }!
        plan.publication = CalendarPublication(plan: plan, workspaceID: "workspace", destination: PublicationDestination(id: "work", title: "Work", accountID: "test"), timeZone: settings.timeZone)
        plan.publication!.state = .published
        let published = plan.publication!.desired.first!
        let remote = CalendarOccurrence(id: published.id, calendarID: "work", title: task.title, calendarTitle: "Work", start: date(660), end: date(720), managedByPlanner: true, plannerCategory: .task, colorID: "11")
        let unrelated = CalendarOccurrence(id: "different", calendarID: "other", title: task.title, calendarTitle: "Other", start: date(660), end: date(720))
        let duplicateTitle = PlanBlock(id: "different-block", title: task.title, kind: .focus, start: block.start, end: block.end, taskID: "different-task")
        plan.blocks.append(duplicateTitle)
        let interval = DateInterval(start: calendar.startOfDay(for: day), duration: 86400)
        let result = CalendarGrid.events(in: interval, google: [remote, unrelated], plans: [plan], tasks: [task])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.filter { $0.taskID == task.id }.count, 1)
        XCTAssertEqual(result.first { $0.taskID == task.id }?.start, date(660))
        XCTAssertEqual(result.first { $0.taskID == task.id }?.googleEventID, published.id)
        XCTAssertEqual(result.first { $0.taskID == task.id }?.planID, plan.id)
        XCTAssertEqual(result.first { $0.taskID == "different-task" }?.status, .draft)
        XCTAssertEqual(CalendarGrid.events(in: interval, google: [remote, unrelated], plans: [plan], tasks: [task], includeLocal: false).count, 2)
    }
    func testLegacyCopiesUseAuthenticatedSourceAndExactTimes() {
        let task = PlannerTask(id: "same-task", title: "Task", state: .done, importance: true, urgency: false, remainingMinutes: 0)
        var plan = Scheduler().makePlan(day: day, now: date(480), tasks: [], routines: [], settings: settings)
        plan.blocks = [PlanBlock(id: "legacy-copy", title: "Task", kind: .focus, start: date(600), end: date(660), taskID: task.id, state: .completed),
            PlanBlock(id: "routine-copy", title: "Movement", kind: .routine, start: date(720), end: date(750), routineID: "movement"),
            PlanBlock(id: "another-time", title: "Movement", kind: .routine, start: date(900), end: date(930), routineID: "movement")]
        let remote = CalendarOccurrence(id: "published-event", calendarID: "work", title: "Task", calendarTitle: "Work", start: date(600), end: date(660), managedByPlanner: true, plannerCategory: .task, plannerTaskID: task.id)
        let routine = CalendarOccurrence(id: "routine-event", calendarID: "work", title: "Movement", calendarTitle: "Work", start: date(720), end: date(750), managedByPlanner: true, plannerCategory: .routine, plannerRoutineID: "movement")
        let interval = DateInterval(start: calendar.startOfDay(for: day), duration: 86400)
        let result = CalendarGrid.events(in: interval, google: [remote, routine], plans: [plan], tasks: [task])
        XCTAssertEqual(result.count, 3); XCTAssertEqual(result.filter { $0.taskID == task.id }.count, 1)
        XCTAssertEqual(result.filter { $0.routineID == "movement" }.count, 2)
        XCTAssertTrue(result.contains { $0.id == plan.id + "|another-time" })
        let foreign = CalendarOccurrence(id: "foreign", calendarID: "work", title: "Task", calendarTitle: "Work", start: date(600), end: date(660), managedByPlanner: false, plannerCategory: .task, plannerTaskID: task.id)
        XCTAssertEqual(foreign.plannerTaskID, nil)
        XCTAssertEqual(CalendarGrid.events(in: interval, google: [foreign], plans: [plan], tasks: [task]).count, 4)
    }
    func testOvernightAndAllDayClippingUseExclusiveDayEnds() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let overnight = CalendarGridEvent(id: "overnight", title: "Night", start: date(1410), end: date(45, day: tomorrow), category: .meeting)
        let allDay = CalendarGridEvent(id: "all-day", title: "Offsite", start: calendar.startOfDay(for: day), end: calendar.startOfDay(for: tomorrow), allDay: true, category: .meeting)
        let first = CalendarGrid.placements(on: day, events: [overnight, allDay], calendar: calendar)
        let second = CalendarGrid.placements(on: tomorrow, events: [overnight, allDay], calendar: calendar)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].duration, 30)
        XCTAssertEqual(second.count, 1); XCTAssertEqual(second[0].startMinute, 0); XCTAssertEqual(second[0].duration, 45)
        let occurrence = CalendarOccurrence(id: "all-day", calendarID: "work", title: "Offsite", calendarTitle: "Work", start: allDay.start, end: allDay.end, allDay: true)
        let nextInterval = DateInterval(start: calendar.startOfDay(for: tomorrow), duration: 86400)
        XCTAssertTrue(CalendarGrid.events(in: nextInterval, google: [occurrence], plans: [], tasks: []).isEmpty)
    }
    func testOccupiedTimeCountsOverlapOnceAndHonorsFreeEvents() {
        var values = [event("A", 540, 600), event("B", 570, 630), event("free", 840, 900, busy: false), event("late", 1005, 1065)]
        XCTAssertEqual(CalendarGrid.occupiedMinutes(on: day, events: values, settings: settings), 105)
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
        values.append(CalendarGridEvent(id: "home", title: "Home", start: start, end: end, allDay: true, busy: false, category: .meeting))
        XCTAssertEqual(CalendarGrid.occupiedMinutes(on: day, events: values, settings: settings), 105)
        values.append(CalendarGridEvent(id: "busy-day", title: "Offsite", start: start, end: end, allDay: true, category: .meeting))
        XCTAssertEqual(CalendarGrid.occupiedMinutes(on: day, events: values, settings: settings), 480)
    }
    func testCalendarWeeksAndDSTKeepActualDurations() {
        let sunday = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
        let days = CalendarGrid.days(containing: sunday, week: true, calendar: calendar)
        XCTAssertEqual(days.count, 7); XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(PlannerDate.key(days[0], settings: settings), "2026-10-26")
        XCTAssertEqual(PlannerDate.key(days[6], settings: settings), "2026-11-01")
        let end = calendar.date(byAdding: .day, value: 1, to: days.last!)!
        XCTAssertEqual(end.timeIntervalSince(days[0]), 169 * 3600)
        let iso = ISO8601DateFormatter()
        let fall = CalendarGridEvent(id: "fall", title: "Clock change", start: iso.date(from: "2026-11-01T01:30:00-04:00")!, end: iso.date(from: "2026-11-01T01:45:00-05:00")!, category: .meeting)
        XCTAssertEqual(CalendarGrid.placements(on: sunday, events: [fall], calendar: calendar)[0].duration, 75)
        let spring = CalendarGridEvent(id: "spring", title: "Clock change", start: iso.date(from: "2026-03-08T01:30:00-05:00")!, end: iso.date(from: "2026-03-08T03:30:00-04:00")!, category: .meeting)
        XCTAssertEqual(CalendarGrid.placements(on: spring.start, events: [spring], calendar: calendar)[0].duration, 60)
    }
}
