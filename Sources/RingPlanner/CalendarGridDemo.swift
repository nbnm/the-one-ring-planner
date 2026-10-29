import Foundation
import RingCore

extension PlannerStore {
    func loadCalendarGridDemo() {
        let days = CalendarGrid.days(containing: now, week: true, calendar: calendar)
        tasks = []; plans = []; calendarGridDemoEvents = []
        for (index, day) in days.enumerated() where index < 5 {
            let prefix = "grid-example-\(index)"
            let publishedTask = PlannerTask(id: prefix + "-proposal", title: index == 3 ? "Rogers · Proposal review" : "8FDE · Product planning", context: "T1A", tags: [index == 3 ? "Rogers" : "8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: 60)
            let draftTask = PlannerTask(id: prefix + "-deepwork", title: index == 1 ? "Prepare the architecture demo" : "Write the delivery plan", context: "T1A", tags: ["8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: index == 1 ? 120 : 90)
            tasks += [publishedTask, draftTask]
            let published = PlanBlock(id: prefix + "-booked", title: publishedTask.title, kind: .focus, start: PlannerDate.at(540, on: day, settings: settings), end: PlannerDate.at(600, on: day, settings: settings), taskID: publishedTask.id)
            let draft = PlanBlock(id: prefix + "-draft", title: draftTask.title, kind: .focus, start: PlannerDate.at(780, on: day, settings: settings), end: PlannerDate.at(index == 1 ? 900 : 870, on: day, settings: settings), taskID: draftTask.id)
            let routine = PlanBlock(id: prefix + "-routine", title: "A little movement", kind: .routine, start: PlannerDate.at(930, on: day, settings: settings), end: PlannerDate.at(960, on: day, settings: settings), routineID: "movement")
            let lunch = PlanBlock(id: prefix + "-lunch", title: "Lunch", kind: .lunch, start: PlannerDate.at(720, on: day, settings: settings), end: PlannerDate.at(750, on: day, settings: settings))
            var plan = Scheduler().makePlan(day: day, now: now, tasks: [], routines: [], settings: settings)
            plan.blocks = [published, draft, routine, lunch]
            plan.publication = CalendarPublication(plan: plan, workspaceID: workspaceID, destination: PublicationDestination(id: "grid-calendar", title: "T1A · Work", accountID: "example"), timeZone: settings.timeZone, confirmedBlockIDs: [published.id])
            plan.publication!.state = .published; plan.publication!.known = plan.publication!.desired
            plans.append(plan)
            let event = plan.publication!.desired[0]
            calendarGridDemoEvents.append(CalendarOccurrence(id: event.id, calendarID: "grid-calendar", title: event.title, calendarTitle: "T1A · Work", start: index == 3 ? event.start.addingTimeInterval(1800) : event.start, end: index == 3 ? event.end.addingTimeInterval(1800) : event.end, managedByPlanner: true, plannerCategory: .task, colorID: "11"))
            calendarGridDemoEvents.append(CalendarOccurrence(id: prefix + "-standup", calendarID: "grid-calendar", title: "Team working session", calendarTitle: "T1A · Work", start: PlannerDate.at(600, on: day, settings: settings), end: PlannerDate.at(645, on: day, settings: settings)))
            if index == 1 { calendarGridDemoEvents.append(CalendarOccurrence(id: prefix + "-overlap", calendarID: "grid-calendar", title: "Partner check-in", calendarTitle: "T1A · Work", start: PlannerDate.at(615, on: day, settings: settings), end: PlannerDate.at(660, on: day, settings: settings))) }
            let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
            calendarGridDemoEvents.append(CalendarOccurrence(id: prefix + "-home", calendarID: "grid-calendar", title: "Home", calendarTitle: "T1A · Work", start: start, end: end, allDay: true, busy: false))
        }
        selectedDay = now; page = .calendar
    }
}
