import Foundation

public struct CalendarEventTime: Equatable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date
    public init(id: String, start: Date, end: Date) { self.id = id; self.start = start; self.end = end }
}

public struct CalendarScheduleUpdate {
    public let plan: DayPlan
    public let changedEvents: Int
    public let conflicts: [String]
    public init(plan: DayPlan, changedEvents: Int, conflicts: [String]) { self.plan = plan; self.changedEvents = changedEvents; self.conflicts = conflicts }
}

public enum CalendarSchedule {
    /// Merge Google times into the publication's original owner. Stable IDs and occurrence
    /// history stay there; day views project moved blocks onto their actual dates.
    public static func reconciling(_ original: DayPlan, times: [CalendarEventTime], settings: PlanningSettings, includingPending: Bool = false) -> CalendarScheduleUpdate {
        guard var publication = original.publication, publication.state != .pending || includingPending else {
            return CalendarScheduleUpdate(plan: original, changedEvents: 0, conflicts: [])
        }
        var plan = original, changed = 0, conflicts: [String] = []
        for time in times where time.start < time.end {
            guard let index = publication.desired.firstIndex(where: { $0.id == time.id }) else { continue }
            let previous = publication.desired[index]
            guard previous.start != time.start || previous.end != time.end else { continue }
            if publication.state == .pending, let baseline = publication.lastPublishedEvents?.first(where: { $0.id == time.id }),
               time.start == baseline.start && time.end == baseline.end {
                // Google still has the baseline: this is an explicitly confirmed local edit.
                continue
            }
            let baseline = publication.lastPublishedEvents?.first { $0.id == time.id }
            let competingLocalEdit = publication.state == .pending && baseline.map { $0.start != previous.start || $0.end != previous.end } == true
            if let blockIndex = plan.blocks.firstIndex(where: { $0.id == previous.blockID && $0.taskID == previous.taskID && $0.routineID == previous.routineID }) {
                if !competingLocalEdit && plan.blocks[blockIndex].start == previous.start && plan.blocks[blockIndex].end == previous.end {
                    plan.blocks[blockIndex].start = time.start; plan.blocks[blockIndex].end = time.end
                    plan.blocks[blockIndex].pinned = true
                    plan.blocks[blockIndex].calendarOwnerDay = publication.day
                } else {
                    conflicts.append(previous.title)
                    publication.state = .needsConfirmation
                    publication.lastError = "This block changed in both the app and Google Calendar. Review its times before confirming."
                }
            }
            publication.desired[index] = previous.rescheduled(start: time.start, end: time.end)
            for i in publication.known.indices where publication.known[i].id == time.id {
                publication.known[i] = publication.known[i].rescheduled(start: time.start, end: time.end)
            }
            if var observed = publication.observedPlanEvents {
                for i in observed.indices where observed[i].id == time.id && observed[i].start == previous.start && observed[i].end == previous.end {
                    observed[i] = observed[i].rescheduled(start: time.start, end: time.end)
                }
                publication.observedPlanEvents = observed
            }
            changed += 1
        }
        if changed > 0 {
            var baselines = Dictionary(uniqueKeysWithValues: (publication.lastPublishedEvents ?? []).map { ($0.id, $0) })
            for time in times {
                if let event = publication.desired.first(where: { $0.id == time.id }) { baselines[time.id] = event.rescheduled(start: time.start, end: time.end) }
            }
            publication.lastPublishedEvents = baselines.values.sorted { $0.id < $1.id }
            plan.publication = publication; plan.revision += 1
            plan = Scheduler().refreshingLayout(plan, settings: settings)
        }
        return CalendarScheduleUpdate(plan: plan, changedEvents: changed, conflicts: conflicts)
    }

    public static func plan(on day: Date, plans: [DayPlan], settings: PlanningSettings, now: Date, forDisplay: Bool = false) -> DayPlan? {
        let key = PlannerDate.key(day, settings: settings)
        let incoming = plans.filter { $0.id != key }.flatMap(\.blocks).filter {
            $0.calendarOwnerDay != nil && PlannerDate.key($0.start, settings: settings) == key && ($0.kind == .focus || $0.kind == .routine)
        }
        guard var result = plans.first(where: { $0.id == key }) ?? (incoming.isEmpty ? nil : emptyPlan(on: day, settings: settings, now: now)) else { return nil }
        let ids = Set(result.blocks.map(\.id))
        result.blocks += incoming.filter { !ids.contains($0.id) }
        if forDisplay {
            result.blocks.removeAll { PlannerDate.key($0.start, settings: settings) != key }
            result = Scheduler().refreshingLayout(result, settings: settings)
        }
        result.blocks.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return result
    }

    /// Projected incoming blocks already live in another saved plan. Never copy or republish them.
    public static func canonical(_ plan: DayPlan) -> DayPlan {
        var result = plan
        result.blocks.removeAll { $0.calendarOwnerDay != nil && $0.calendarOwnerDay != plan.id }
        return result
    }
    private static func emptyPlan(on day: Date, settings: PlanningSettings, now: Date) -> DayPlan {
        DayPlan(id: PlannerDate.key(day, settings: settings), revision: 0, status: .local, outcomeIDs: [], blocks: [], unscheduled: [], warnings: [],
                workMinutes: 0, fixedMinutes: 0, reserveMinutes: 0, createdAt: now)
    }
}

public struct TaskScheduleEntry: Equatable, Identifiable {
    public enum Status: String { case calendar = "Scheduled", pending = "Pending", draft = "Draft", unavailable = "Check calendar" }
    public let id: String
    public let start: Date
    public let end: Date
    public let status: Status
    public var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    public static func entries(taskID: String, plans: [DayPlan], now: Date, edits: [CalendarBlockEdit] = []) -> [Self] {
        var entries: [String: Self] = [:]
        for plan in plans {
            let closed = Set(plan.blocks.filter { $0.state != .planned && $0.state != .running }.map(\.id))
            for block in plan.blocks where block.taskID == taskID && block.end > now && (block.state == .planned || block.state == .running) {
                let id = plan.id + "|" + block.id
                entries[id] = Self(id: id, start: block.start, end: block.end, status: .draft)
            }
            for event in plan.publication?.desired ?? [] where event.taskID == taskID && event.end > now && !closed.contains(event.blockID) {
                let id = plan.id + "|" + event.blockID
                let status: Status = plan.publication?.state == .pending ? .pending : (plan.publication?.missingEventIDs?.contains(event.id) == true ? .unavailable : .calendar)
                entries[id] = Self(id: id, start: event.start, end: event.end, status: status)
            }
        }
        for edit in edits where edit.unresolved && edit.event.taskID == taskID && edit.event.end > now {
            let id = edit.publication.day + "|" + edit.event.blockID
            entries[id] = Self(id: id, start: edit.event.start, end: edit.event.end, status: edit.state == .conflict ? .unavailable : .pending)
        }
        return entries.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
