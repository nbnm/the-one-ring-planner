import Foundation
import CryptoKit

public struct EventReminder: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let kind: String
    public var fireDate: Date { start.addingTimeInterval(-60) }
    public init(sourceID: String, title: String, start: Date, end: Date, kind: String) {
        let hash = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        id = "ring.event." + hash; self.title = title; self.start = start; self.end = end; self.kind = kind
    }
}

public enum EventReminderPlanner {
    /// Fresh Google occurrences own their times. Saved meeting snapshots and unpublished
    /// drafts never generate alerts, and a mirrored local block must not alert twice.
    public static func reminders(events: [CalendarOccurrence], plans: [DayPlan], tasks: [PlannerTask], now: Date, limit: Int = 60) -> [EventReminder] {
        var result: [String: EventReminder] = [:]
        func append(_ reminder: EventReminder) {
            guard reminder.fireDate > now, reminder.end > reminder.start else { return }
            result[reminder.id] = reminder
        }
        func activeTask(_ id: String?) -> Bool {
            guard let id, let task = tasks.first(where: { $0.id == id }) else { return true }
            return task.isEligible
        }
        for event in events where !event.allDay {
            if event.managedByPlanner {
                guard activeTask(event.plannerTaskID) else { continue }
                let owner = plans.first { $0.id == event.plannerDay }
                if let block = owner?.blocks.first(where: { $0.id == event.plannerBlockID }), block.state != .planned { continue }
            }
            append(EventReminder(sourceID: "google|\(event.calendarID)|\(event.sourceEventID)", title: event.title, start: event.start, end: event.end,
                                 kind: event.managedByPlanner ? (event.plannerCategory == .routine ? "Routine" : "Task") : "Calendar event"))
        }
        for plan in plans where plan.status == .local && plan.publication == nil {
            for block in plan.blocks where block.state == .planned && (block.kind == .focus || block.kind == .routine) {
                guard activeTask(block.taskID), block.calendarOwnerDay == nil || block.calendarOwnerDay == plan.id else { continue }
                append(EventReminder(sourceID: "local|\(plan.id)|\(block.id)", title: block.title, start: block.start, end: block.end,
                                     kind: block.kind == .routine ? "Routine" : "Task"))
            }
        }
        return Array(result.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.prefix(max(0, limit)))
    }
}
