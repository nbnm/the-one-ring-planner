import Foundation
import CryptoKit

/// A dated snapshot survives reopening, subsequent edits and deletion of the active task.
public struct TaskCompletion: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public let id: String
    public let taskSnapshot: PlannerTask
    public let completedAt: Date?
    public let recordedAt: Date
    public let blockID: String?
    public var restoredAt: Date?
    public var taskID: String { taskSnapshot.id }
    public init(id: String = UUID().uuidString.lowercased(), task: PlannerTask, completedAt: Date?, recordedAt: Date, blockID: String? = nil) {
        self.id = id; taskSnapshot = task; self.completedAt = completedAt; self.recordedAt = recordedAt; self.blockID = blockID
    }
}
public struct TaskRestoration {
    public var task: PlannerTask
    public var completion: TaskCompletion
}
public enum TaskHistoryError: LocalizedError {
    case alreadyActive, changed
    public var errorDescription: String? {
        switch self {
        case .alreadyActive: return "This task has already been restored. Its completion history is kept."
        case .changed: return "A newer completion exists for this task. Restore its latest completion instead."
        }
    }
}
public enum TaskHistory {
    public static func latest(taskID: String, completions: [TaskCompletion]) -> TaskCompletion? {
        completions.filter { $0.taskID == taskID }.max {
            if $0.taskSnapshot.revision != $1.taskSnapshot.revision { return $0.taskSnapshot.revision < $1.taskSnapshot.revision }
            return $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt < $1.recordedAt
        }
    }
    public static func restore(_ completion: TaskCompletion, current: PlannerTask?, completions: [TaskCompletion], now: Date) throws -> TaskRestoration {
        guard completion.restoredAt == nil else { throw TaskHistoryError.alreadyActive }
        guard latest(taskID: completion.taskID, completions: completions)?.id == completion.id else { throw TaskHistoryError.changed }
        if let current {
            guard current.id == completion.taskID else { throw TaskHistoryError.changed }
            guard current.state == .done || (current.state == .archived && current.completionID == completion.id) else { throw TaskHistoryError.alreadyActive }
            guard current.completionID == completion.id else { throw TaskHistoryError.changed }
        }
        var task = current ?? completion.taskSnapshot
        task.state = .inbox; task.importance = nil; task.urgency = nil; task.completedAt = nil; task.completionID = nil
        let previous = completion.taskSnapshot.remainingMinutes ?? 0
        task.remainingMinutes = previous > 0 ? previous : max(25, task.minimumBlockMinutes)
        task.minimumBlockMinutes = max(5, min(task.minimumBlockMinutes, task.remainingMinutes!))
        task.schemaVersion = 3; task.updatedAt = now; task.revision += 1
        var entry = completion; entry.restoredAt = now
        return TaskRestoration(task: task, completion: entry)
    }
    /// Older releases did not save completion times. Retain those tasks without inventing dates.
    public static func migratingLegacy(tasks: [PlannerTask], completions: [TaskCompletion], now: Date) -> (tasks: [PlannerTask], completions: [TaskCompletion]) {
        var changed: [PlannerTask] = [], entries: [TaskCompletion] = []
        for var task in tasks where task.state == .done && task.completionID == nil {
            if let existing = latest(taskID: task.id, completions: completions), existing.restoredAt == nil {
                task.completionID = existing.id; task.completedAt = existing.completedAt
            } else {
                let digest = SHA256.hash(data: Data("\(task.id)|\(task.revision)|\(task.updatedAt.timeIntervalSince1970)".utf8)).map { String(format: "%02x", $0) }.joined()
                let entry = TaskCompletion(id: "legacy-" + digest, task: task, completedAt: task.completedAt, recordedAt: now)
                entries.append(entry); task.completionID = entry.id
            }
            task.revision += 1; changed.append(task)
        }
        return (changed, entries)
    }
}
