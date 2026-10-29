import Foundation

public struct CalendarGridEvent: Equatable, Identifiable, Sendable {
    public enum Category: String, Sendable { case task, routine, meeting, pause, transition }
    public enum Status: String, Sendable { case google = "Google Calendar", draft = "Local draft", pending = "Pending publication", review = "Saved plan · review calendar", completed = "Completed", interrupted = "Paused", free = "Free event" }
    public let id: String
    public let title: String
    public let context: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let busy: Bool
    public let category: Category
    public let status: Status
    public let taskID: String?
    public let routineID: String?
    public let blockID: String?
    public let planID: String?
    public let calendarID: String?
    public let googleEventID: String?
    public var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    public var isLocal: Bool { googleEventID == nil }
    public init(id: String, title: String, context: String = "", start: Date, end: Date, allDay: Bool = false, busy: Bool = true, category: Category, status: Status = .draft, taskID: String? = nil, routineID: String? = nil, planID: String? = nil, blockID: String? = nil, calendarID: String? = nil, googleEventID: String? = nil) {
        self.id = id; self.title = title; self.context = context; self.start = start; self.end = end; self.allDay = allDay; self.busy = busy
        self.category = category; self.status = status; self.taskID = taskID; self.routineID = routineID; self.planID = planID; self.blockID = blockID; self.calendarID = calendarID; self.googleEventID = googleEventID
    }
}
public struct CalendarGridPlacement: Identifiable, Equatable {
    public var id: String { event.id }
    public let event: CalendarGridEvent
    public let startMinute: Double
    public let endMinute: Double
    public let lane: Int
    public let laneCount: Int
    public var duration: Double { endMinute - startMinute }
}
public enum CalendarGrid {
    /// Join by authenticated Google identity, never by title or coincident event times.
    public static func events(in interval: DateInterval, google: [CalendarOccurrence], plans: [DayPlan], tasks: [PlannerTask], includeLocal: Bool = true, includeTransitions: Bool = false, edits: [CalendarBlockEdit] = [], readAt: Date? = nil) -> [CalendarGridEvent] {
        struct Owner { let plan: DayPlan; let event: CalendarPlanEvent }
        var owners: [String: Owner] = [:]
        for plan in plans {
            guard let publication = plan.publication else { continue }
            for event in publication.known + publication.desired { owners[publication.destination.id + "|" + event.id] = Owner(plan: plan, event: event) }
        }
        let remote = google.filter { $0.start < interval.end && $0.end > interval.start && $0.start < $0.end }
        let visibleRemote = Set(remote.filter(\.managedByPlanner).map { $0.calendarID + "|" + $0.sourceEventID })
        var result = remote.map { occurrence -> CalendarGridEvent in
            let owner = occurrence.managedByPlanner ? owners[occurrence.calendarID + "|" + occurrence.sourceEventID] : nil
            let taskID = owner?.event.taskID ?? occurrence.plannerTaskID
            let routineID = owner?.event.routineID ?? occurrence.plannerRoutineID
            let task = tasks.first { $0.id == taskID }
            let status: CalendarGridEvent.Status = !occurrence.busy ? .free : task?.state == .done ? .completed : .google
            return CalendarGridEvent(id: occurrence.id, title: occurrence.title, context: occurrence.calendarTitle, start: occurrence.start, end: occurrence.end, allDay: occurrence.allDay, busy: occurrence.busy,
                category: occurrence.plannerCategory == .task ? .task : occurrence.plannerCategory == .routine ? .routine : .meeting, status: status,
                taskID: taskID, routineID: routineID, planID: owner?.plan.id ?? occurrence.plannerDay, blockID: owner?.event.blockID ?? occurrence.plannerBlockID, calendarID: occurrence.calendarID, googleEventID: occurrence.sourceEventID)
        }
        let remoteItems = result
        if includeLocal {
            for plan in plans {
                for block in plan.blocks where block.start < interval.end && block.end > interval.start && block.start < block.end && block.kind != .meeting && block.state != .skipped && (block.calendarOwnerDay == nil || block.calendarOwnerDay == plan.id) {
                    if block.kind == .transition && !includeTransitions { continue }
                    if let task = tasks.first(where: { $0.id == block.taskID }), (task.state == .done || task.state == .archived || task.state == .inbox) && (block.state == .planned || block.state == .running) { continue }
                    if let publication = plan.publication,
                       let published = (publication.desired + publication.known).first(where: { $0.blockID == block.id }),
                       visibleRemote.contains(publication.destination.id + "|" + published.id) { continue }
                    // Older plans can retain a copied block under a different ID after an import.
                    // Suppress only its exact source/time twin, backed by authenticated Google metadata.
                    if remoteItems.contains(where: { remote in
                        remote.start == block.start && remote.end == block.end &&
                        ((block.taskID != nil && remote.taskID == block.taskID && remote.routineID == nil) ||
                         (block.routineID != nil && remote.routineID == block.routineID && remote.taskID == nil))
                    }) { continue }
                    let category: CalendarGridEvent.Category = block.kind == .focus ? .task : block.kind == .routine ? .routine : block.kind == .transition ? .transition : .pause
                    let recorded = plan.publication?.desired.contains { $0.blockID == block.id } == true
                    let status: CalendarGridEvent.Status = block.state == .completed ? .completed : block.state == .interrupted ? .interrupted : recorded ? (plan.publication?.state == .pending ? .pending : .review) : .draft
                    result.append(CalendarGridEvent(id: plan.id + "|" + block.id, title: block.title, context: block.context, start: block.start, end: block.end, category: category, status: status, taskID: block.taskID, routineID: block.routineID, planID: plan.id, blockID: block.id))
                }
            }
        }
        // Keep optimistic times visible until a successful fresh range read acknowledges them.
        for edit in edits.sorted(by: { ($0.syncedAt ?? .distantFuture) < ($1.syncedAt ?? .distantFuture) }) where edit.unresolved || (edit.state == .synced && (readAt ?? .distantPast) < (edit.syncedAt ?? .distantPast)) {
            let e = edit.event, p = edit.publication
            result.removeAll { ($0.calendarID == p.destination.id && $0.googleEventID == e.id) || ($0.planID == p.day && $0.blockID == e.blockID) }
            if e.start < interval.end && e.end > interval.start {
                result.append(CalendarGridEvent(id: "edit-" + edit.id, title: e.title, context: p.destination.title, start: e.start, end: e.end, category: e.routineID == nil ? .task : .routine, status: edit.unresolved ? .pending : .google, taskID: e.taskID, routineID: e.routineID, planID: p.day, blockID: e.blockID, calendarID: p.destination.id, googleEventID: e.id))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public static func days(containing date: Date, week: Bool, calendar: Calendar) -> [Date] {
        var c = calendar; c.firstWeekday = 2
        let start = week ? (c.dateInterval(of: .weekOfYear, for: date)?.start ?? c.startOfDay(for: date)) : c.startOfDay(for: date)
        return (0..<(week ? 7 : 1)).compactMap { c.date(byAdding: .day, value: $0, to: start) }
    }
    public static func minute(_ date: Date, on day: Date, calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
        if date <= start { return 0 }; if date >= end { return 1440 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }
    /// Interval partitioning keeps an entire overlap group at one consistent column width.
    public static func placements(on day: Date, events: [CalendarGridEvent], calendar: Calendar) -> [CalendarGridPlacement] {
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
        let timed = events.filter { !$0.allDay && $0.start < end && $0.end > start }.sorted { $0.start == $1.start ? ($0.end == $1.end ? $0.id < $1.id : $0.end > $1.end) : $0.start < $1.start }
        var groups: [[CalendarGridEvent]] = [], current: [CalendarGridEvent] = [], groupEnd = Date.distantPast
        for event in timed {
            if !current.isEmpty && event.start >= groupEnd { groups.append(current); current = [] }
            current.append(event); groupEnd = max(current.count == 1 ? event.end : groupEnd, event.end)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.flatMap { group -> [CalendarGridPlacement] in
            var ends: [Date] = [], assigned: [(CalendarGridEvent, Int)] = []
            for event in group {
                let clippedStart = max(start, event.start), clippedEnd = min(end, event.end)
                let lane = ends.firstIndex { $0 <= clippedStart } ?? ends.count
                if lane == ends.count { ends.append(clippedEnd) } else { ends[lane] = clippedEnd }
                assigned.append((event, lane))
            }
            return assigned.map { event, lane in
                let a = max(start, event.start), b = min(end, event.end)
                let from = minute(a, on: day, calendar: calendar)
                return CalendarGridPlacement(event: event, startMinute: from, endMinute: from + b.timeIntervalSince(a) / 60, lane: lane, laneCount: ends.count)
            }
        }
    }
    public static func occupiedMinutes(on day: Date, events: [CalendarGridEvent], settings: PlanningSettings) -> Int {
        let start = PlannerDate.at(settings.workStart, on: day, settings: settings), end = PlannerDate.at(settings.workEnd, on: day, settings: settings)
        let intervals = events.filter(\.busy).compactMap { event -> DateInterval? in
            let a = max(start, event.start), b = min(end, event.end)
            return a < b ? DateInterval(start: a, end: b) : nil
        }.sorted { $0.start < $1.start }
        var seconds = 0.0, finish = start
        for interval in intervals { seconds += max(0, interval.end.timeIntervalSince(max(finish, interval.start))); finish = max(finish, interval.end) }
        return Int(seconds / 60)
    }
}
