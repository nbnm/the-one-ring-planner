import Foundation
import Combine
import RingCore

extension PlannerStore {
    func startEventAlerts() {
        eventAlerts.source = { [weak self] in
            guard let self else { return EventAlertSnapshot(reminders: []) }
            return try await self.readEventAlerts()
        }
        eventAlertUpdates = Publishers.MergeMany([
            $plans.map { _ in () }.eraseToAnyPublisher(),
            $tasks.map { _ in () }.eraseToAnyPublisher(),
            $settings.map { _ in () }.eraseToAnyPublisher(),
            calendarConnection.$enabled.map { _ in () }.eraseToAnyPublisher(),
            calendarConnection.$selectedIDs.map { _ in () }.eraseToAnyPublisher(),
            $calendarGridRevision.map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.eventAlerts.refreshSoon() }
        eventAlerts.start()
    }
    private func readEventAlerts() async throws -> EventAlertSnapshot {
        let date = Date(), revision = calendarConnection.readRevision
        var events: [CalendarOccurrence] = [], warning: String?
        if calendarConnection.enabled {
            // An independent rolling range keeps alerts on the actual day when the user
            // browses a different week. Reading it does not replace planning snapshots.
            let interval = DateInterval(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(48 * 3600))
            do {
                let read = try await calendarConnection.readRange(interval)
                guard calendarConnection.readRevision == revision else { throw CalendarConnectionError.changedDuringRead }
                eventAlertRead = (revision, read); events = read.events
            } catch {
                guard let cached = eventAlertRead, cached.revision == revision else { throw error }
                events = cached.read.events
                warning = "Google Calendar could not refresh. Alerts use its last successful read and will retry in a minute."
            }
            guard calendarConnection.readRevision == revision, calendarConnection.enabled else { throw CalendarConnectionError.changedDuringRead }
        } else { eventAlertRead = nil }
        return EventAlertSnapshot(reminders: EventReminderPlanner.reminders(events: events, plans: plans, tasks: tasks, now: Date()), warning: warning)
    }
}
