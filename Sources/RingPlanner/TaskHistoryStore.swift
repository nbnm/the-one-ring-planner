import Foundation
import RingCore

extension PlannerStore {
    func canRestoreCompletion(_ entry: TaskCompletion) -> Bool {
        (try? TaskHistory.restore(entry, current: tasks.first { $0.id == entry.taskID }, completions: completions, now: now)) != nil
    }
    func openHistoryPlan(_ plan: DayPlan) {
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone; format.dateFormat = "yyyy-MM-dd"
        if let date = format.date(from: plan.id) { selectedDay = date }
        page = .today
    }
}
