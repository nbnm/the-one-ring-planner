import Foundation

public struct PlanningPreview {
    public let workMinutes: Int
    public let elapsedMinutes: Int
    public let calendarMinutes: Int
    public let lunchMinutes: Int
    public let routineMinutes: Int
    public let committedTaskMinutes: Int
    public let transitionMinutes: Int
    public let reserveMinutes: Int
    public let reserveShortfallMinutes: Int
    public let availableMinutes: Int
    public let selectedEffortMinutes: Int
    public let scheduledEffortMinutes: Int
    public let unscheduledTasks: [Unscheduled]
    public let proposedPlan: DayPlan

    init(day: Date, now: Date, tasks: [PlannerTask], settings: PlanningSettings, baseline: DayPlan, proposed: DayPlan, selectedTaskIDs: [String]?) {
        proposedPlan = proposed
        let start = PlannerDate.at(settings.workStart, on: day, settings: settings)
        let end = PlannerDate.at(settings.workEnd, on: day, settings: settings)
        let calendar = PlannerDate.calendar(settings)
        let roundedNow = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 300) * 300)
        let availableStart = calendar.startOfDay(for: day) < calendar.startOfDay(for: now) ? end :
            (calendar.isDate(day, inSameDayAs: now) ? min(end, max(start, roundedNow)) : start)
        workMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        elapsedMinutes = max(0, Int(availableStart.timeIntervalSince(start) / 60))
        // Attribute overlapping commitments only once, in this order. All intervals are
        // clipped to the future work window; elapsed time is accounted for separately.
        var used: [PlanBlock] = []
        func add(_ kind: BlockKind) -> Int {
            let before = Self.occupied(used, start: availableStart, end: end)
            used += baseline.blocks.filter { $0.kind == kind }
            return Self.occupied(used, start: availableStart, end: end) - before
        }
        calendarMinutes = add(.meeting)
        lunchMinutes = add(.lunch)
        routineMinutes = add(.routine)
        committedTaskMinutes = add(.focus)
        transitionMinutes = add(.transition)
        let free = max(0, workMinutes - elapsedMinutes - Self.occupied(used, start: availableStart, end: end))
        reserveMinutes = min(free, baseline.reserveMinutes)
        reserveShortfallMinutes = max(0, baseline.reserveMinutes - reserveMinutes)
        availableMinutes = max(0, free - reserveMinutes)
        let ids = selectedTaskIDs.map(Set.init)
        let selected = tasks.filter { $0.isEligible && $0.quadrant != .reconsider && (ids?.contains($0.id) ?? true) }
        let chosen = Set(selected.map(\.id))
        selectedEffortMinutes = selected.reduce(0) { $0 + ($1.remainingMinutes ?? 0) }
        scheduledEffortMinutes = selected.reduce(0) { sum, task in
            let held = proposed.blocks.filter { $0.taskID == task.id && ($0.state == .planned || $0.state == .running) && $0.start < end && $0.end > availableStart }.reduce(0) { $0 + max(0, Int(min($1.end, end).timeIntervalSince(max($1.start, availableStart)) / 60)) }
            return sum + min(task.remainingMinutes ?? 0, held)
        }
        unscheduledTasks = proposed.unscheduled.filter { chosen.contains($0.id) }
    }
    private static func occupied(_ blocks: [PlanBlock], start: Date, end: Date) -> Int {
        var intervals: [(Date, Date)] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            let begin = max(start, block.start), finish = min(end, block.end)
            guard begin < finish else { continue }
            if let last = intervals.last, begin <= last.1 { intervals[intervals.count - 1].1 = max(last.1, finish) }
            else { intervals.append((begin, finish)) }
        }
        return intervals.reduce(0) { $0 + Int($1.1.timeIntervalSince($1.0) / 60) }
    }
}
