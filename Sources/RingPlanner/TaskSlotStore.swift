import Foundation
import RingCore

struct TaskSlotRequest: Identifiable {
    let id = UUID()
    let task: PlannerTask
    let minutes: Int
    let day: Date
    let existingStart: Date?
}
struct TaskSlotCalendarSnapshot {
    let read: CalendarRead
    let revision: UUID
    let gridRevision: UUID
    let fetchedAt: Date
}
enum TaskSlotError: LocalizedError {
    case changed, calendar, unavailable
    var errorDescription: String? {
        switch self {
        case .changed: return "This task or day changed. Close this review and find a time for its latest version."
        case .calendar: return "Connect Google Calendar in Settings before choosing and publishing a task time."
        case .unavailable: return "That time is no longer available. Choose another gap on the calendar."
        }
    }
}
extension PlannerStore {
    func offerTimeSlot(for task: PlannerTask) {
        guard task.isEligible, task.quadrant == .schedule else { return }
        let entries = scheduledEntries(for: task).filter { $0.status != .unavailable }
        let remaining = max(0, (task.remainingMinutes ?? 0) - entries.reduce(0) { $0 + $1.minutes })
        taskSlotRequest = TaskSlotRequest(task: task, minutes: remaining, day: TaskSlotPlanner.searchStart(now: now, settings: settings), existingStart: entries.first?.start)
    }
    private func slotCalendar(start: Date, days: Int = 14, fresh: Bool = false) async throws -> CalendarRead {
        let c = calendar, a = c.startOfDay(for: start), b = c.date(byAdding: .day, value: days, to: a)!
        let interval = DateInterval(start: a, end: b)
        if isDemo {
            let events = calendarGridDemoEvents + plans.flatMap { p in p.blocks.filter { $0.kind == .meeting }.map { CalendarOccurrence(id: $0.id, calendarID: "example", title: $0.title, calendarTitle: "Example", start: $0.start, end: $0.end) } }
            return CalendarRead(interval: interval, calendarIDs: ["example"], events: events.filter { $0.start < b && $0.end > a })
        }
        guard calendarConnection.enabled else { throw TaskSlotError.calendar }
        if publicationDestinations.isEmpty { await refreshPublishingSettings() }
        guard let destination = publicationDestination else { throw CalendarPublicationError.destination }
        if !calendarConnection.selectedIDs.contains(destination.id) { calendarConnection.select(destination.id, included: true) }
        if !fresh, let cache = taskSlotCalendarCache, cache.revision == calendarConnection.readRevision, cache.gridRevision == calendarGridRevision,
           cache.read.interval.start <= a, cache.read.interval.end >= b, Date().timeIntervalSince(cache.fetchedAt) < 60 {
            return cache.read
        }
        let revision = calendarConnection.readRevision, gridRevision = calendarGridRevision
        let read = try await calendarConnection.readRange(interval)
        guard revision == calendarConnection.readRevision else { throw TaskSlotError.changed }
        taskSlotCalendarCache = TaskSlotCalendarSnapshot(read: read, revision: revision, gridRevision: gridRevision, fetchedAt: Date())
        return read
    }
    /// Availability follows the fresh range, including moved/removed planner events. This
    /// is a read-only projection; search never edits a saved plan or republishes events.
    func taskSlotDisplayPlans(_ read: CalendarRead) -> [DayPlan] {
        plans.map { original in
            guard var publication = original.publication else { return original }
            let events = read.events.filter { $0.managedByPlanner && $0.calendarID == publication.destination.id }
            let times = events.map { CalendarEventTime(id: $0.sourceEventID, start: $0.start, end: $0.end) }
            var p = CalendarSchedule.reconciling(original, times: times, settings: settings, includingPending: true, tasks: tasks).plan
            publication = p.publication!
            let visible = Set(events.map(\.sourceEventID))
            let missing = publication.desired.filter { $0.start < read.interval.end && $0.end > read.interval.start && !visible.contains($0.id) }
            publication.missingEventIDs = Array(Set((publication.missingEventIDs ?? []).filter { !visible.contains($0) } + missing.map(\.id))).sorted()
            let removedBlocks = Set(missing.map(\.blockID))
            p.blocks.removeAll { removedBlocks.contains($0.id) && $0.state == .planned }
            p.publication = publication
            return p
        }
    }
    private func slotContext(day: Date, read: CalendarRead) -> (meetings: [PlanBlock], busy: [PlanBlock], previous: DayPlan?) {
        let a = calendar.startOfDay(for: day), b = calendar.date(byAdding: .day, value: 1, to: a)!, window = DateInterval(start: a, end: b)
        var external: [PlanBlock] = [], owned: [PlanBlock] = []
        for event in read.events {
            guard var block = event.meeting(in: window) else { continue }
            if event.managedByPlanner {
                block.kind = event.plannerCategory == .routine ? .routine : .focus
                block.context = event.plannerTaskID.flatMap { id in tasks.first(where: { $0.id == id })?.context } ?? ""
                owned.append(block)
            } else { external.append(block) }
        }
        let previous = CalendarSchedule.plan(on: day, plans: isDemo ? plans : taskSlotDisplayPlans(read), settings: settings, now: now)
        return (external, owned, previous)
    }
    func findTaskSlots(request: TaskSlotRequest, starting day: Date, notBefore: Int, minutes: Int, weekends: Bool, excluding: Set<String>, automaticFit: Bool = false) async throws -> [TaskTimeSlot] {
        guard tasks.first(where: { $0.id == request.task.id })?.revision == request.task.revision else { throw TaskSlotError.changed }
        let snapshot = settings, read = try await slotCalendar(start: day)
        var examined = 0
        for offset in 0..<14 {
            try Task.checkCancellation()
            let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: day))!
            if request.task.area == .work && !weekends && calendar.isDateInWeekend(date) { continue }
            examined += 1
            guard snapshot == settings, tasks.first(where: { $0.id == request.task.id })?.revision == request.task.revision else { throw TaskSlotError.changed }
            let context = slotContext(day: date, read: read)
            let lengths = TaskSlotPlanner.candidateLengths(task: request.task, minutes: minutes, focusMinutes: snapshot.focusMinutes, automaticFit: automaticFit)
            var options: [TaskTimeSlot] = []
            for amount in lengths {
                let matches = TaskSlotPlanner.suggestions(task: request.task, minutes: amount, day: date, now: now, tasks: tasks, routines: routines, settings: snapshot, meetings: context.meetings, previous: context.previous, notBeforeMinute: notBefore, excluding: excluding, reserveIsHardLimit: false, calendarBusy: context.busy)
                options.append(contentsOf: matches)
            }
            options.sort { $0.start == $1.start ? $0.minutes > $1.minutes : $0.start < $1.start }
            if !options.isEmpty { return Array(options.prefix(3)) }
            if examined >= 7 { break }
        }
        return []
    }
    func assessTaskSlot(_ slot: TaskTimeSlot, request: TaskSlotRequest, manual: Bool) async throws -> TaskSlotAssessment {
        let snapshot = settings, read = try await slotCalendar(start: slot.start, days: 1)
        guard snapshot == settings, tasks.first(where: { $0.id == request.task.id })?.revision == request.task.revision else { throw TaskSlotError.changed }
        let context = slotContext(day: slot.start, read: read)
        return TaskSlotPlanner.assessment(slot, task: request.task, now: now, tasks: tasks, routines: routines, settings: snapshot, meetings: context.meetings, previous: context.previous, calendarBusy: context.busy, manual: manual)
    }
    @discardableResult func acceptTaskSlot(_ slot: TaskTimeSlot, request: TaskSlotRequest, manual: Bool = false) async throws -> Bool {
        guard !publishingCalendar, !buildingPlan else { return false }
        buildingPlan = true
        defer { buildingPlan = false }
        let snapshot = settings, key = PlannerDate.key(slot.start, settings: settings), original = plans.first { $0.id == PlannerDate.key(slot.start, settings: settings) }
        guard !calendarEdits.contains(where: { $0.unresolved && $0.publication.day == key }) else { throw TaskSlotError.changed }
        let read = try await slotCalendar(start: slot.start, days: 1, fresh: true)
        guard snapshot == settings, let task = tasks.first(where: { $0.id == slot.taskID }), task.revision == request.task.revision,
              plans.first(where: { $0.id == key }) == original else { throw TaskSlotError.changed }
        let allocated = scheduledEntries(for: task).filter { $0.status != .unavailable }.reduce(0) { $0 + $1.minutes }
        guard slot.minutes <= max(0, (task.remainingMinutes ?? 0) - allocated) else { throw TaskSlotError.changed }
        let context = slotContext(day: slot.start, read: read)
        let checked = TaskSlotPlanner.assessment(slot, task: task, now: now, tasks: tasks, routines: routines, settings: snapshot, meetings: context.meetings, previous: context.previous, calendarBusy: context.busy, manual: manual)
        guard checked.canBook else { throw MeetingError.validation(checked.blocking.joined(separator: " ")) }
        var p = TaskSlotPlanner.accepting(slot, task: task, now: now, tasks: tasks, routines: routines, settings: snapshot, meetings: context.meetings, previous: context.previous)
        if isDemo {
            guard savePlan(p, message: "Accept example Q2 time slot") else { return false }
            selectedDay = slot.start; page = .calendar; taskSlotCalendarCache = nil; showNotice("Example slot accepted. Google Calendar was not changed."); return true
        }
        guard let destination = original?.publication?.destination ?? publicationDestination else { throw CalendarPublicationError.destination }
        let oldIDs = Set(context.previous?.blocks.map(\.id) ?? [])
        guard let added = p.blocks.first(where: { $0.taskID == task.id && !oldIDs.contains($0.id) && $0.start == slot.start && $0.end == slot.end }) else { throw TaskSlotError.changed }
        let event = CalendarPlanEvent.events(plan: p, workspaceID: workspaceID, timeZone: snapshot.timeZone).first { $0.blockID == added.id }!
        if let publication = p.publication { p.publication = CalendarBlockEditing.recording(event, in: publication, acknowledged: false) }
        else { p.publication = CalendarPublication(plan: p, workspaceID: workspaceID, destination: destination, timeZone: snapshot.timeZone, confirmedBlockIDs: [added.id]) }
        if p.publication!.missingEventIDs?.isEmpty == false { p.publication!.state = .needsConfirmation }
        var scope = p.publication!; scope.desired = [event]; scope.known = [event]; scope.confirmedBlockIDs = [added.id]; scope.observedPlanEvents = [event]
        let edit = CalendarBlockEdit(publication: scope, baselineStart: slot.start, baselineEnd: slot.end, creating: true)
        p.status = .local
        guard persist(message: "Accept Q2 calendar time and queue only this event", calendarEdits: [edit], plan: p, apply: {}) else { return false }
        selectedDay = slot.start; page = .calendar; taskSlotCalendarCache = nil; calendarGridRevision = UUID()
        await retryCalendarEdits(force: true)
        return true
    }
}
