import Foundation

/// Pure, deterministic placement. Calendar publication is deliberately outside this module.
public struct Scheduler {
    public init() {}
    public func makePlan(day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock] = [], previous: DayPlan? = nil, outcomeIDs: [String] = [], selectedTaskIDs: [String]? = nil) -> DayPlan {
        draft(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, outcomeIDs: outcomeIDs, selectedTaskIDs: selectedTaskIDs, placeNewTasks: true)
    }
    public func reservingPlan(day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?) -> DayPlan {
        draft(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, outcomeIDs: previous?.outcomeIDs ?? [], selectedTaskIDs: nil, placeNewTasks: false)
    }
    /// Builds both estimates in memory; neither result changes the saved day plan.
    public func preview(day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock] = [], previous: DayPlan? = nil, outcomeIDs: [String] = [], selectedTaskIDs: [String]? = nil) -> PlanningPreview {
        let baseline = draft(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, outcomeIDs: outcomeIDs, selectedTaskIDs: selectedTaskIDs, placeNewTasks: false)
        let proposed = makePlan(day: day, now: now, tasks: tasks, routines: routines, settings: s, meetings: meetings, previous: previous, outcomeIDs: outcomeIDs, selectedTaskIDs: selectedTaskIDs)
        return PlanningPreview(day: day, now: now, tasks: tasks, settings: s, baseline: baseline, proposed: proposed, selectedTaskIDs: selectedTaskIDs)
    }
    private func draft(day: Date, now: Date, tasks: [PlannerTask], routines: [Routine], settings s: PlanningSettings, meetings: [PlanBlock], previous: DayPlan?, outcomeIDs: [String], selectedTaskIDs: [String]?, placeNewTasks: Bool) -> DayPlan {
        let selection = selectedTaskIDs.map { Set($0) }
        let selectedOutcomes = outcomeIDs.filter { selection?.contains($0) ?? true }
        let key = PlannerDate.key(day, settings: s)
        let start = PlannerDate.at(s.workStart, on: day, settings: s)
        let end = PlannerDate.at(s.workEnd, on: day, settings: s)
        let sameDay = PlannerDate.key(now, settings: s) == key
        let earliest = sameDay ? max(start, rounded(now)) : start
        let dueRoutines = routines.filter { $0.occurs(on: day, settings: s) }
        var warnings: [String] = []
        var omitted: [Unscheduled] = []
        let personalWindow = s.taskWindow(.personal, on: day)
        let personalStart = PlannerDate.at(personalWindow.start, on: day, settings: s), personalEnd = PlannerDate.at(personalWindow.end, on: day, settings: s)
        let hasPersonal = tasks.contains { $0.area == .personal && $0.isEligible }
        let visibleStart = hasPersonal ? min(start, personalStart) : start, visibleEnd = hasPersonal ? max(end, personalEnd) : end
        var blocks = meetings.filter { $0.end > visibleStart && $0.start < visibleEnd }
        if s.lunchMinutes > 0 {
            blocks.append(.init(id: "\(key)-lunch", title: "Lunch & a proper pause", kind: .lunch, start: PlannerDate.at(s.lunchStart, on: day, settings: s), end: PlannerDate.at(s.lunchStart + s.lunchMinutes, on: day, settings: s)))
        }
        // Retain completed work, pins, protected occurrences and the near-term/running block.
        let offDay = (previous?.blocks ?? []).filter { block in
            guard block.calendarOwnerDay == key && PlannerDate.key(block.start, settings: s) != key && (block.kind == .focus || block.kind == .routine) else { return false }
            if block.state != .planned { return true }
            if let id = block.taskID { return tasks.first { $0.id == id }?.isEligible == true && (selection?.contains(id) ?? true) }
            return dueRoutines.contains { $0.id == block.routineID }
        }
        let offDayIDs = Set(offDay.map(\.id))
        let retained = (previous?.blocks ?? []).filter { block in
            if offDayIDs.contains(block.id) { return false }
            guard block.kind == .focus || block.kind == .routine else { return false }
            // Incoming calendar blocks are fixed bookings owned by a different date.
            if let owner = block.calendarOwnerDay, owner != key { return true }
            if block.state == .completed || block.state == .running { return true }
            if block.kind == .routine {
                // Closing an occurrence must not create another one on the next replan.
                if block.state == .interrupted || block.state == .skipped { return true }
                // Explicit repeat-day changes apply even to unstarted protected/pinned occurrences.
                guard dueRoutines.contains(where: { $0.id == block.routineID }) else { return false }
            }
            if let id = block.taskID {
                guard tasks.first(where: { $0.id == id })?.isEligible == true,
                      selection?.contains(id) ?? true else { return false }
            }
            return block.pinned || block.protected || (sameDay && block.start < now.addingTimeInterval(Double(s.freezeMinutes * 60)) && block.end > now)
        }
        blocks += retained
        let workMinutes = Int(end.timeIntervalSince(start) / 60)
        let fixedOnly = blocks.filter { $0.kind == .meeting || $0.kind == .lunch }
        let fixedMinutes = occupied(fixedOnly + transitions(fixedOnly, start: start, end: end, s: s), start: start, end: end)
        let reserve = (max(0, workMinutes - fixedMinutes) * s.reservePercent / 100 / 5) * 5
        let budget = max(0, workMinutes - reserve)
        var serial = 0
        func place(id: String, title: String, context: String, kind: BlockKind, duration: Int, minimum: Int, split: Bool, windowStart: Date, windowEnd: Date, taskID: String? = nil, routineID: String? = nil, protected: Bool = false, personal: Bool = false) -> Int {
            guard duration > 0 else { return 0 }
            var remaining = duration
            let effectiveMin = max(5, minimum)
            while remaining > 0 {
                var amount = split ? min(s.focusMinutes, remaining) : remaining
                if split && remaining > amount && remaining - amount < effectiveMin { amount = remaining - effectiveMin }
                guard amount >= effectiveMin else { break }
                var found: PlanBlock?
                // Try the longest useful chunk first, then reduce by the five-minute grid.
                while amount >= effectiveMin && found == nil {
                    let first = personal ? (sameDay ? max(personalStart, rounded(now)) : personalStart) : earliest
                    var candidateStart = rounded(max(first, windowStart))
                    let limit = min(personal ? personalEnd : end, windowEnd)
                    while candidateStart.addingTimeInterval(Double(amount * 60)) <= limit {
                        let candidateEnd = candidateStart.addingTimeInterval(Double(amount * 60))
                        while blocks.contains(where: { $0.id == "\(key)-\(id)-\(serial)" }) { serial += 1 }
                        let candidate = PlanBlock(id: "\(key)-\(id)-\(serial)", title: title, context: context, kind: kind, start: candidateStart, end: candidateEnd, taskID: taskID, routineID: routineID, protected: protected)
                        let ordered = (blocks + [candidate]).sorted(by: order)
                        let index = ordered.firstIndex { $0.id == candidate.id }!
                        let before = index > 0 ? ordered[index - 1] : nil
                        let after = index + 1 < ordered.count ? ordered[index + 1] : nil
                        let fitsBefore = before.map { candidateStart >= $0.end.addingTimeInterval(Double(gap($0, candidate, s: s) * 60)) } ?? true
                        let fitsAfter = after.map { candidateEnd.addingTimeInterval(Double(gap(candidate, $0, s: s) * 60)) <= $0.start } ?? true
                        if fitsBefore && fitsAfter {
                            let occupiedMinutes = occupied(ordered + transitions(ordered, start: start, end: end, s: s), start: start, end: end)
                            if personal || occupiedMinutes <= budget { found = candidate; break }
                        }
                        candidateStart = candidateStart.addingTimeInterval(300)
                    }
                    if !split { break }
                    if found == nil { amount -= 5 }
                }
                guard let found else { break }
                blocks.append(found); serial += 1; remaining -= found.minutes
            }
            return remaining
        }
        for r in dueRoutines.filter({ $0.protected }).sorted(by: { $0.id < $1.id }) where !(retained + offDay).contains(where: { $0.routineID == r.id }) {
            let left = place(id: r.id, title: r.title, context: "Protected routine", kind: .routine, duration: r.minutes, minimum: r.minutes, split: false, windowStart: PlannerDate.at(r.startMinute, on: day, settings: s), windowEnd: PlannerDate.at(r.endMinute, on: day, settings: s), routineID: r.id, protected: true)
            if left > 0 { omitted.append(.init(id: r.id, title: r.title, minutes: left, reason: "Protected routine does not fit its window. Review the day.")) }
        }
        let ready = tasks.filter { $0.isEligible && (selection?.contains($0.id) ?? true) }.sorted { a, b in
            func priority(_ t: PlannerTask) -> Int {
                if t.quadrant == .doFirst { return 0 }
                if selectedOutcomes.first == t.id { return 1 }
                if selectedOutcomes.contains(t.id) { return 2 }
                return t.quadrant == .schedule ? 3 : (t.quadrant == .delegate ? 4 : 5)
            }
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            if a.deadline != b.deadline { return (a.deadline ?? .distantFuture) < (b.deadline ?? .distantFuture) }
            if a.context != b.context { return a.context < b.context }
            return a.id < b.id
        }
        var admin = 0
        for task in ready where placeNewTasks {
            let held = (retained + offDay).filter { $0.taskID == task.id && $0.state != .completed && $0.state != .interrupted && $0.state != .skipped }.reduce(0) { $0 + $1.minutes }
            let minutes = max(0, (task.remainingMinutes ?? 0) - held)
            guard minutes > 0 else { continue }
            let reason: String?
            if task.quadrant == .reconsider { reason = "Q4 stays outside the automatic plan." }
            else if TaskArea.from(task.tags) == .work && PlannerDate.calendar(s).isDateInWeekend(day) { reason = "Work tasks stay on working days. Change the tag to Personal for weekend planning." }
            else if task.dependencies.contains(where: { id in tasks.first(where: { $0.id == id })?.state != .done }) { reason = "Waiting for a prerequisite to finish." }
            else if task.area == .work && task.quadrant == .delegate && admin + minutes > s.adminBudget { reason = "Outside the \(s.adminBudget)-minute admin budget." }
            else { reason = nil }
            if let reason { omitted.append(.init(id: task.id, title: task.title, minutes: minutes, reason: reason)); continue }
            let window = s.taskWindow(task.area, on: day)
            let taskStart = PlannerDate.at(window.start, on: day, settings: s), taskEnd = PlannerDate.at(window.end, on: day, settings: s)
            let left = place(id: task.id, title: task.title, context: task.context, kind: .focus, duration: minutes, minimum: task.minimumBlockMinutes, split: task.allowsSplitting, windowStart: max(taskStart, task.earliestStart ?? taskStart), windowEnd: min(taskEnd, task.deadline ?? taskEnd), taskID: task.id, personal: task.area == .personal)
            if task.area == .work && task.quadrant == .delegate { admin += minutes - left }
            if left > 0 {
                omitted.append(.init(id: task.id, title: task.title, minutes: left, reason: task.deadline != nil ? "Deadline at risk: insufficient room before the deadline." : "No useful block fits after transitions and the interruption reserve."))
            }
        }
        for r in dueRoutines.filter({ !$0.protected }).sorted(by: { $0.id < $1.id }) where !(retained + offDay).contains(where: { $0.routineID == r.id }) {
            guard r.important || r.urgent else { omitted.append(.init(id: r.id, title: r.title, minutes: r.minutes, reason: "Q4 routine stays outside the automatic plan.")); continue }
            let left = place(id: r.id, title: r.title, context: "Flexible routine", kind: .routine, duration: r.minutes, minimum: r.minutes, split: false, windowStart: PlannerDate.at(r.startMinute, on: day, settings: s), windowEnd: PlannerDate.at(r.endMinute, on: day, settings: s), routineID: r.id)
            if left > 0 { omitted.append(.init(id: r.id, title: r.title, minutes: left, reason: "Higher-priority work filled the routine window.")) }
        }
        let sorted = blocks.sorted(by: order)
        for pair in zip(sorted, sorted.dropFirst()) {
            let needed = gap(pair.0, pair.1, s: s)
            let available = Int(pair.1.start.timeIntervalSince(pair.0.end) / 60)
            if available < 0 { warnings.append("Overlap: \(pair.0.title) and \(pair.1.title). Fixed times preserved.") }
            else if available < needed { warnings.append("Missing \(needed - available)-minute transition between \(pair.0.title) and \(pair.1.title).") }
        }
        blocks += transitions(blocks, start: visibleStart, end: visibleEnd, s: s)
        return DayPlan(id: key, revision: (previous?.revision ?? 0) + 1, status: .draft, outcomeIDs: selectedOutcomes, selectedTaskIDs: selection.map { $0.sorted() }, publication: previous?.publication, blocks: (blocks + offDay).sorted(by: order), unscheduled: omitted, warnings: warnings, workMinutes: workMinutes, fixedMinutes: fixedMinutes, reserveMinutes: reserve, createdAt: now, previousBlocks: previous?.blocks, capacityStart: start, capacityEnd: end)
    }
    /// Rebuild only layout metadata after a calendar move; never place or move other work.
    public func refreshingLayout(_ plan: DayPlan, settings s: PlanningSettings, tasks: [PlannerTask] = []) -> DayPlan {
        var result = plan
        let f = DateFormatter(); f.calendar = PlannerDate.calendar(s); f.timeZone = f.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: plan.id) else { return result }
        let start = PlannerDate.at(s.workStart, on: day, settings: s), end = PlannerDate.at(s.workEnd, on: day, settings: s)
        result.blocks.removeAll { $0.kind == .transition }
        let visible = result.blocks.filter { PlannerDate.key($0.start, settings: s) == plan.id }.sorted(by: order)
        result.warnings.removeAll { $0.hasPrefix("Overlap:") || $0.hasPrefix("Missing ") || $0.hasPrefix("Outside work hours:") }
        for block in visible where (block.kind == .focus || block.kind == .routine) && (block.start < start || block.end > end) && !tasks.contains(where: { $0.id == block.taskID && $0.area == .personal }) {
            result.warnings.append("Outside work hours: \(block.title). Calendar time preserved.")
        }
        for (a, b) in zip(visible, visible.dropFirst()) {
            let available = Int(b.start.timeIntervalSince(a.end) / 60), needed = gap(a, b, s: s)
            if available < 0 { result.warnings.append("Overlap: \(a.title) and \(b.title). Calendar times preserved.") }
            else if available < needed { result.warnings.append("Missing \(needed - available)-minute transition between \(a.title) and \(b.title).") }
        }
        result.blocks += transitions(visible, start: start, end: end, s: s)
        result.blocks.sort(by: order)
        result.capacityStart = start; result.capacityEnd = end
        result.workMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let fixed = visible.filter { $0.kind == .meeting || $0.kind == .lunch }
        result.fixedMinutes = occupied(fixed + transitions(fixed, start: start, end: end, s: s), start: start, end: end)
        result.reserveMinutes = (max(0, result.workMinutes - result.fixedMinutes) * s.reservePercent / 100 / 5) * 5
        return result
    }
    private func order(_ a: PlanBlock, _ b: PlanBlock) -> Bool { a.start == b.start ? a.id < b.id : a.start < b.start }
    private func rounded(_ date: Date) -> Date { Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / 300) * 300) }
    private func gap(_ a: PlanBlock, _ b: PlanBlock, s: PlanningSettings) -> Int {
        let outgoing = a.kind == .meeting ? s.meetingRecovery : (a.kind == .lunch ? 0 : s.relatedTransition)
        let incoming = b.kind == .meeting ? s.meetingPreparation : (b.kind == .lunch ? 0 : (a.context != b.context && !a.context.isEmpty && !b.context.isEmpty ? s.projectTransition : s.relatedTransition))
        return max(outgoing, incoming)
    }
    private func transitions(_ blocks: [PlanBlock], start: Date, end: Date, s: PlanningSettings) -> [PlanBlock] {
        let sorted = blocks.sorted(by: order)
        var result: [PlanBlock] = []
        if let first = sorted.first, first.kind == .meeting {
            let time = first.start.addingTimeInterval(-Double(s.meetingPreparation * 60))
            if time >= start { result.append(.init(id: "prep-\(first.id)", title: "Meeting preparation", kind: .transition, start: time, end: first.start)) }
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let minutes = gap(a, b, s: s)
            let finish = a.end.addingTimeInterval(Double(minutes * 60))
            if minutes > 0 && finish <= b.start && a.end >= start && finish <= end {
                result.append(.init(id: "gap-\(a.id)-\(b.id)", title: a.kind == .meeting ? "Recover & reset" : "Save progress & reset", kind: .transition, start: a.end, end: finish))
            }
        }
        if let last = sorted.last, last.kind == .meeting {
            let finish = last.end.addingTimeInterval(Double(s.meetingRecovery * 60))
            if finish <= end { result.append(.init(id: "recovery-\(last.id)", title: "Recover & reset", kind: .transition, start: last.end, end: finish)) }
        }
        return result
    }
    private func occupied(_ blocks: [PlanBlock], start: Date, end: Date) -> Int {
        var intervals: [(Date, Date)] = []
        for b in blocks.sorted(by: order) {
            let a = max(start, b.start), z = min(end, b.end)
            guard a < z else { continue }
            if let last = intervals.last, a <= last.1 { intervals[intervals.count - 1].1 = max(last.1, z) }
            else { intervals.append((a, z)) }
        }
        return intervals.reduce(0) { $0 + Int($1.1.timeIntervalSince($1.0) / 60) }
    }
}
