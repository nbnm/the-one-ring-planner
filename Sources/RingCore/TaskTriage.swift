import Foundation

public enum TaskRequirement: String, CaseIterable, Equatable {
    case title, priority, duration, minimumBlock
    public var label: String {
        switch self {
        case .title: return "An actionable title"
        case .priority: return "A confirmed priority"
        case .duration: return "A duration of at least 5 minutes"
        case .minimumBlock: return "A useful block that fits the remaining effort"
        }
    }
}

/// A proposed drop or menu selection is a draft. Only a fully reviewed task may leave Inbox.
public enum TaskTriage {
    public static func proposing(_ task: PlannerTask, quadrant: Quadrant) -> PlannerTask {
        var draft = task
        draft.importance = quadrant == .doFirst || quadrant == .schedule
        draft.urgency = quadrant == .doFirst || quadrant == .delegate
        return draft
    }
    public static func missingRequirements(_ task: PlannerTask) -> [TaskRequirement] {
        var missing: [TaskRequirement] = []
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.title) }
        if task.quadrant == nil { missing.append(.priority) }
        if (task.remainingMinutes ?? 0) < 5 { missing.append(.duration) }
        if task.minimumBlockMinutes < 5 || (task.remainingMinutes.map { $0 >= 5 && task.minimumBlockMinutes > $0 } ?? false) { missing.append(.minimumBlock) }
        return missing
    }
    public static func readyForPlacement(_ draft: PlannerTask) -> PlannerTask? {
        guard missingRequirements(draft).isEmpty, draft.state != .done, draft.state != .archived else { return nil }
        var task = draft
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.state == .inbox { task.state = .ready }
        return task
    }
}
