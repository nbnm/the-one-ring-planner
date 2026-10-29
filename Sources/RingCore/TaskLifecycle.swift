import Foundation

public enum TaskDisposition { case complete, archive, inbox, delete }

public struct TaskDispositionChange {
    public let task: PlannerTask?
    public let plans: [DayPlan]
    public let captures: [Capture]
    public let deletingTaskIDs: [String]
    public let completions: [TaskCompletion]
}

/// A single transaction changes the task and every saved plan that references it.
public enum TaskLifecycle {
    public static func change(_ original: PlannerTask, to disposition: TaskDisposition, plans: [DayPlan], captures: [Capture] = [], now: Date, completedBlockID: String? = nil) -> TaskDispositionChange {
        if disposition == .complete && original.state == .done {
            return TaskDispositionChange(task: original, plans: [], captures: [], deletingTaskIDs: [], completions: [])
        }
        let deleting = disposition == .delete
        var task = original
        task.revision += 1; task.updatedAt = now
        var completions: [TaskCompletion] = []
        if disposition == .complete {
            let entry = TaskCompletion(task: original, completedAt: now, recordedAt: now, blockID: completedBlockID)
            completions = [entry]; task.state = .done; task.remainingMinutes = 0; task.completedAt = now; task.completionID = entry.id
        }
        if disposition == .archive { task.state = .archived }
        if disposition == .inbox { task.state = .inbox; task.importance = nil; task.urgency = nil; task.completedAt = nil; task.completionID = nil }
        func clean(_ blocks: [PlanBlock], history: Bool = false) -> [PlanBlock] {
            let removed = Set(blocks.filter { $0.taskID == task.id && (deleting || $0.state == .planned) }.map(\.id))
            return blocks.compactMap { block in
                if removed.contains(block.id) { return nil }
                if block.kind == .transition && removed.contains(where: { block.id == "prep-\($0)" || block.id == "recovery-\($0)" || block.id.hasPrefix("gap-\($0)-") || block.id.hasSuffix("-\($0)") }) { return nil }
                var changed = block
                if !history && changed.taskID == task.id && changed.state == .running {
                    changed.state = disposition == .complete ? .completed : .interrupted
                    changed.actualMinutes = min(changed.minutes, max(0, Int(now.timeIntervalSince(changed.actualStartedAt ?? now) / 60)))
                }
                return changed
            }
        }
        let changedPlans = plans.compactMap { originalPlan -> DayPlan? in
            var p = originalPlan
            p.blocks = clean(p.blocks)
            if deleting { p.previousBlocks = p.previousBlocks.map { clean($0, history: true) } }
            p.outcomeIDs.removeAll { $0 == task.id }
            p.selectedTaskIDs?.removeAll { $0 == task.id }
            p.unscheduled.removeAll { $0.id == task.id }
            if deleting && !original.title.isEmpty { p.warnings.removeAll { $0.contains(original.title) } }
            guard p != originalPlan else { return nil }
            p.schemaVersion = 2; p.revision += 1; p.status = .draft
            return p
        }
        let changedCaptures: [Capture] = deleting ? captures.filter { $0.taskIDs.contains(task.id) }.map { capture in
            var c = capture; c.taskIDs.removeAll { $0 == task.id }; return c
        } : []
        // Dependencies deliberately remain unresolved when their prerequisite is deleted.
        return TaskDispositionChange(task: deleting ? nil : task, plans: changedPlans, captures: changedCaptures, deletingTaskIDs: deleting ? [task.id] : [], completions: completions)
    }
}
