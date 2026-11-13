import Foundation

public struct TaskTimeSlot: Identifiable, Equatable, Sendable {
    public let taskID: String
    public let start: Date
    public let end: Date
    public init(taskID: String, start: Date, end: Date) { self.taskID = taskID; self.start = start; self.end = end }
    public var id: String { "\(taskID)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)" }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public enum TaskSlotPlanner {
    /// Start Q2 searches from today, independently of the calendar page last browsed.
    public static func searchStart(now: Date, settings: PlanningSettings) -> Date { PlannerDate.calendar(settings).startOfDay(for: now) }
    public static func candidateLengths(task: PlannerTask, minutes: Int, focusMinutes: Int, automaticFit: Bool) -> [Int] {
        guard automaticFit, task.allowsSplitting else { return [minutes] }
        let minimum = max(5, min(task.minimumBlockMinutes, minutes))
        return Array(Set([minutes, minutes - minimum, focusMinutes, 90, 60, 45, 30, minimum].filter {
            $0 >= minimum && $0 <= minutes && ($0 == minutes || minutes - $0 >= minimum)
        })).sorted(by: >)
    }
    public static func suggestions(task: PlannerTask, minutes: Int, day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?, notBeforeMinute: Int, excluding: Set<String> = [], limit: Int = 3, reserveIsHardLimit: Bool = true, calendarBusy: [PlanBlock] = []) -> [TaskTimeSlot] {
        let window = s.taskWindow(task.area, on: day)
        let start = PlannerDate.at(window.start, on: day, settings: s), end = PlannerDate.at(window.end, on: day, settings: s)
        let lower = max(start, now, task.earliestStart ?? start, PlannerDate.at(notBeforeMinute, on: day, settings: s))
        let upper = min(end, task.deadline ?? end)
        guard minutes >= 5, minutes <= 1440 else { return [] }
        var cursor = Date(timeIntervalSince1970: ceil(lower.timeIntervalSince1970 / 300) * 300), result: [TaskTimeSlot] = []
        let context = context(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, calendarBusy: calendarBusy)
        while cursor.addingTimeInterval(Double(minutes * 60)) <= upper && result.count < limit {
            let slot = TaskTimeSlot(taskID: task.id, start: cursor, end: cursor.addingTimeInterval(Double(minutes * 60)))
            if !excluding.contains(slot.id), assess(slot, task: task, now: now, tasks: tasks, settings: s, context: context, manual: false, reserveIsHardLimit: reserveIsHardLimit).canBook { result.append(slot) }
            cursor = cursor.addingTimeInterval(Double(((result.last?.id == slot.id || excluding.contains(slot.id)) ? max(30, minutes) : 5) * 60))
        }
        return result
    }
    public static func assessment(_ slot: TaskTimeSlot, task: PlannerTask, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?, calendarBusy: [PlanBlock] = [], manual: Bool = true, reserveIsHardLimit: Bool = false) -> TaskSlotAssessment {
        assess(slot, task: task, now: now, tasks: tasks, settings: s, context: context(day: slot.start, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, calendarBusy: calendarBusy), manual: manual, reserveIsHardLimit: reserveIsHardLimit)
    }
    private struct Context { let busy: [PlanBlock]; let baseline: DayPlan; let day: Date }
    private static func context(day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?, calendarBusy: [PlanBlock]) -> Context {
        var prior = previous
        if prior != nil {
            let missingBlocks = Set((prior!.publication?.desired ?? []).filter { prior!.publication?.missingEventIDs?.contains($0.id) == true }.map(\.blockID))
            // Calendar snapshots replace old meetings. Closed work and stale transitions
            // must not occupy future slots merely because an earlier draft retained them.
            prior!.blocks.removeAll { b in
                missingBlocks.contains(b.id) || b.kind == .meeting || b.kind == .transition || b.kind == .lunch || b.state == .completed || b.state == .interrupted || b.state == .skipped ||
                (b.taskID != nil && tasks.first(where: { $0.id == b.taskID })?.isEligible != true)
            }
            for i in prior!.blocks.indices where prior!.blocks[i].kind == .routine { prior!.blocks[i].pinned = true }
        }
        let baseline = Scheduler().reservingPlan(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: prior)
        var busy = (baseline.blocks + (prior?.blocks ?? [])).filter { $0.kind != .transition && ($0.state == .planned || $0.state == .running) } + meetings + calendarBusy
        let closed = Set((previous?.blocks ?? []).filter { $0.state != .planned && $0.state != .running }.map(\.id))
        for e in previous?.publication?.desired ?? [] where previous?.publication?.missingEventIDs?.contains(e.id) != true && !closed.contains(e.blockID) {
            guard e.taskID == nil || tasks.first(where: { $0.id == e.taskID })?.isEligible == true else { continue }
            busy.append(PlanBlock(id: "published-" + e.id, title: e.title, context: e.context, kind: e.kind, start: e.start, end: e.end))
        }
        return Context(busy: busy, baseline: baseline, day: day)
    }
    private static func assess(_ slot: TaskTimeSlot, task: PlannerTask, now: Date, tasks: [PlannerTask], settings s: PlanningSettings, context: Context, manual: Bool, reserveIsHardLimit: Bool) -> TaskSlotAssessment {
        var blocked: [String] = [], warnings: [String] = []
        let minimum = max(5, min(task.minimumBlockMinutes, task.remainingMinutes ?? 0))
        guard slot.taskID == task.id, task.isEligible, task.quadrant == .schedule, slot.start < slot.end, slot.minutes >= minimum, slot.minutes <= 1440, slot.minutes <= (task.remainingMinutes ?? 0) else { return TaskSlotAssessment(blocking: ["Choose a useful block within the task’s remaining duration."], warnings: []) }
        if slot.start < now { blocked.append("Choose a time in the future.") }
        if task.dependencies.contains(where: { id in tasks.first { $0.id == id }?.state != .done }) { blocked.append("Finish this task’s prerequisites first.") }
        if let earliest = task.earliestStart, slot.start < earliest { blocked.append("This starts before the task’s earliest start.") }
        if let deadline = task.deadline, slot.end > deadline { blocked.append("This ends after the task’s deadline.") }
        let c = PlannerDate.calendar(s), dayStart = c.startOfDay(for: slot.start), dayEnd = c.date(byAdding: .day, value: 1, to: dayStart)!
        if slot.end > dayEnd { blocked.append("Choose a block within one calendar day.") }
        let window = s.taskWindow(task.area, on: slot.start)
        let start = PlannerDate.at(window.start, on: slot.start, settings: s), end = PlannerDate.at(window.end, on: slot.start, settings: s)
        if slot.start < start || slot.end > end {
            let label = task.area == .personal ? "personal" : "work"
            if manual { warnings.append("Outside your usual \(label) hours.") } else { blocked.append("Outside \(label) hours.") }
        }
        if manual && task.area == .work && c.isDateInWeekend(slot.start) { warnings.append("This is a weekend.") }
        let busy = context.busy
        let overlaps = busy.filter { $0.start < slot.end && $0.end > slot.start }
        if !overlaps.isEmpty { blocked.append("Overlaps " + Array(Set(overlaps.map(\.title))).sorted().prefix(3).joined(separator: ", ") + ".") }
        let before = busy.filter { $0.end <= slot.start }.max { $0.end < $1.end }, after = busy.filter { $0.start >= slot.end }.min { $0.start < $1.start }
        let preparation = before.map { max($0.kind == .meeting ? s.meetingRecovery : s.relatedTransition, !$0.context.isEmpty && !task.context.isEmpty && $0.context != task.context ? s.projectTransition : s.relatedTransition) } ?? 0
        let recovery = after.map { max(s.relatedTransition, $0.kind == .meeting ? s.meetingPreparation : (!$0.context.isEmpty && !task.context.isEmpty && $0.context != task.context ? s.projectTransition : s.relatedTransition)) } ?? 0
        if before.map({ slot.start.timeIntervalSince($0.end) < Double(preparation * 60) }) == true || after.map({ $0.start.timeIntervalSince(slot.end) < Double(recovery * 60) }) == true {
            if manual { warnings.append("Leaves less than your usual transition buffer.") } else { blocked.append("Leaves insufficient transition time.") }
        }
        var occupied = busy + [PlanBlock(id: "candidate", title: task.title, kind: .focus, start: slot.start, end: slot.end)]
        if preparation > 0 { occupied.append(PlanBlock(id: "before", title: "Transition", kind: .transition, start: slot.start.addingTimeInterval(-Double(preparation * 60)), end: slot.start)) }
        if recovery > 0 { occupied.append(PlanBlock(id: "after", title: "Transition", kind: .transition, start: slot.end, end: slot.end.addingTimeInterval(Double(recovery * 60)))) }
        if task.area == .work && unionMinutes(occupied, start: start, end: end) > context.baseline.workMinutes - context.baseline.reserveMinutes {
            if reserveIsHardLimit { blocked.append("Uses the day’s interruption reserve.") } else { warnings.append("Uses interruption reserve normally kept free in automatic day plans.") }
        }
        return TaskSlotAssessment(blocking: blocked, warnings: warnings)
    }
    public static func accepting(_ slot: TaskTimeSlot, task: PlannerTask, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?) -> DayPlan {
        var prior = previous ?? Scheduler().reservingPlan(day: slot.start, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: nil)
        // Keep previously confirmed events at their confirmed times. Unconfirmed work
        // stays local and is not implicitly published by accepting this one task.
        for event in prior.publication?.desired ?? [] where prior.publication?.missingEventIDs?.contains(event.id) != true {
            if let index = prior.blocks.firstIndex(where: { $0.id == event.blockID }), prior.blocks[index].state != .planned { continue }
            let wasProtected = prior.blocks.first { $0.id == event.blockID }?.protected ?? false
            let ownerDay = prior.blocks.first { $0.id == event.blockID }?.calendarOwnerDay
            prior.blocks.removeAll { $0.id == event.blockID }
            var restored = PlanBlock(id: event.blockID, title: event.title, context: event.context, kind: event.kind, start: event.start, end: event.end, taskID: event.taskID, routineID: event.routineID, pinned: true, protected: wasProtected)
            restored.calendarOwnerDay = ownerDay
            prior.blocks.append(restored)
        }
        let originalPins = Dictionary(uniqueKeysWithValues: prior.blocks.map { ($0.id, $0.pinned) })
        for i in prior.blocks.indices where prior.blocks[i].kind == .focus || prior.blocks[i].kind == .routine { prior.blocks[i].pinned = true }
        let block = PlanBlock(id: "slot-\(UUID().uuidString.lowercased())", title: task.title, context: task.context, kind: .focus, start: slot.start, end: slot.end, taskID: task.id, pinned: true)
        prior.blocks.append(block)
        var plan = Scheduler().reservingPlan(day: slot.start, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: prior)
        for i in plan.blocks.indices { if let pin = originalPins[plan.blocks[i].id] { plan.blocks[i].pinned = pin } }
        plan.previousBlocks = previous?.blocks
        plan.selectedTaskIDs = previous?.selectedTaskIDs.map { Array(Set($0 + [task.id])).sorted() }
        return plan
    }
    private static func unionMinutes(_ blocks: [PlanBlock], start: Date, end: Date) -> Int {
        var intervals: [(Date, Date)] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            let a = max(start, block.start), b = min(end, block.end)
            guard a < b else { continue }
            if let last = intervals.last, a <= last.1 { intervals[intervals.count - 1].1 = max(last.1, b) }
            else { intervals.append((a, b)) }
        }
        return intervals.reduce(0) { $0 + Int($1.1.timeIntervalSince($1.0) / 60) }
    }
}

public struct TaskSlotAssessment: Equatable, Sendable {
    public let blocking: [String]
    public let warnings: [String]
    public var canBook: Bool { blocking.isEmpty }
    public init(blocking: [String], warnings: [String]) { self.blocking = blocking; self.warnings = warnings }
}
