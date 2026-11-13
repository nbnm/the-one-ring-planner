import Foundation
import RingCore

extension PlannerStore {
    func synchronizeCalendarSchedule() async {
        if let task = calendarScheduleTask { await task.value; return }
        guard !isDemo, calendarConnection.enabled, !publishingCalendar else { return }
        syncingCalendarSchedule = true
        let task = Task { await self.readCalendarSchedule() }
        calendarScheduleTask = task
        await task.value
        calendarScheduleTask = nil; syncingCalendarSchedule = false
    }
    private func readCalendarSchedule() async {
        let settingsSnapshot = settings
        let originals = plans.filter { $0.publication?.desired.isEmpty == false }.sorted { $0.id < $1.id }
        var updates: [(DayPlan, CalendarScheduleUpdate)] = []
        var missing = 0
        do {
            for original in originals {
                let held = Set(calendarEdits.filter { $0.unresolved && $0.publication.day == original.id }.map { $0.event.id })
                var reading = original.publication!; reading.desired.removeAll { held.contains($0.id) }
                let times = try await googleCalendar.eventTimes(reading, skippingRemoved: true)
                guard calendarConnection.enabled, settings == settingsSnapshot, !publishingCalendar else { throw CalendarConnectionError.changedDuringRead }
                let merged = CalendarSchedule.reconciling(original, times: times, settings: settingsSnapshot, includingPending: true, tasks: tasks)
                var plan = merged.plan
                let found = Set(times.map(\.id)), absent = original.publication!.desired.map(\.id).filter { !found.contains($0) && !held.contains($0) }.sorted()
                plan.publication!.missingEventIDs = absent.isEmpty ? nil : absent
                let update = CalendarScheduleUpdate(plan: plan, changedEvents: merged.changedEvents, conflicts: merged.conflicts)
                if original.publication?.state != .pending || original.publication?.lastError != nil { missing += absent.count }
                if update.plan != original { updates.append((original, update)) }
            }
            guard updates.allSatisfy({ original, _ in plans.first(where: { $0.id == original.id }) == original }) else { throw CalendarConnectionError.changedDuringRead }
            if !updates.isEmpty {
                guard savePlans(updates.map { $0.1.plan }, message: "Import Google Calendar schedule changes") else {
                    calendarScheduleError = error ?? "Calendar changes could not be saved. Refresh to retry."; calendarScheduleReadFailed = true; return
                }
                let count = updates.reduce(0) { $0 + $1.1.changedEvents }
                if count > 0 { showNotice("Updated \(count) \(count == 1 ? "scheduled block" : "scheduled blocks") from Google Calendar.") }
            }
            let conflicted = plans.contains { $0.publication?.state == .needsConfirmation && $0.publication?.lastError?.contains("changed in both") == true }
            calendarScheduleError = conflicted ? "Some blocks changed in both places. Review the app’s draft before confirming its calendar changes." : (missing > 0 ? "\(missing) planner \(missing == 1 ? "event is" : "events are") missing from Google. Last saved times are kept; other event times are synced." : nil)
            calendarScheduleLastRead = Date()
            calendarScheduleReadFailed = false
        } catch {
            calendarScheduleError = "Couldn’t sync planner event times. \(error.localizedDescription) Refresh to retry."
            calendarScheduleReadFailed = true
        }
    }

    func scheduledEntries(for task: PlannerTask) -> [TaskScheduleEntry] { TaskScheduleEntry.entries(taskID: task.id, plans: plans, now: now, edits: calendarEdits) }
    func scheduledDate(_ date: Date, includeYear: Bool = false) -> String {
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.dateFormat = includeYear ? "EEE, MMM d, yyyy · HH:mm" : "EEE, MMM d · HH:mm"
        return format.string(from: date)
    }
}
