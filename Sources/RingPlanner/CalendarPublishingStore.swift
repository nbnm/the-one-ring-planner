import Foundation
import RingCore

extension PlannerStore {
    func applyCalendarColors() async {
        guard !isDemo, !publishingCalendar, !enablingCalendarWriting else { return }
        publishingCalendar = true; updatingCalendarColors = true
        calendarColorNotice = nil; calendarColorError = nil
        defer { publishingCalendar = false; updatingCalendarColors = false }
        do {
            calendarWritingAllowed = await googleCalendar.oauth.publishingAuthorized()
            guard calendarWritingAllowed else { throw GoogleCalendarError.publishingPermission }
            var changed = 0
            for publication in plans.compactMap(\.publication).sorted(by: { $0.day < $1.day }) {
                changed += try await googleCalendar.applyEventColors(publication)
            }
            calendarColorNotice = changed == 0 ? "Planner event colors are up to date." : "Updated colors for \(changed) \(changed == 1 ? "event" : "events"). Tasks are red; routine activities are green."
        } catch { calendarColorError = "Couldn’t update all event colors. \(error.localizedDescription) Try again to finish the remaining events." }
        if calendarConnection.enabled { await calendarConnection.refresh(day: selectedDay, settings: settings) }
    }
    var publicationDestination: PublicationDestination? {
        publicationDestinations.first { $0.id == publicationCalendarID } ??
        publicationDestinations.first { $0.primary && calendarConnection.selectedIDs.contains($0.id) } ??
        publicationDestinations.first { calendarConnection.selectedIDs.contains($0.id) } ?? publicationDestinations.first
    }
    var publicationDestinationTitle: String { plan?.publication?.destination.title ?? publicationDestination?.title ?? "your Google calendar" }
    func publicationDestinationTitle(for day: Date) -> String { plans.first { $0.id == PlannerDate.key(day, settings: settings) }?.publication?.destination.title ?? publicationDestination?.title ?? "your Google calendar" }
    func refreshPublishingSettings() async {
        if isDemo {
            publicationDestinations = [.init(id: "example", title: "Example calendar", accountID: "example", primary: true)]
            return
        }
        calendarWritingAllowed = await googleCalendar.oauth.publishingAuthorized()
        guard calendarConnection.enabled, await googleCalendar.oauth.authorized() else { publicationDestinations = []; return }
        do {
            publicationDestinations = try await googleCalendar.publicationDestinations()
            publicationSettingsError = nil
        } catch { publicationSettingsError = error.localizedDescription }
    }
    func selectPublicationCalendar(_ id: String) {
        guard publicationDestinations.contains(where: { $0.id == id }) else { return }
        publicationCalendarID = id
        publicationDefaults.set(id, forKey: "googleCalendar.publicationDestination")
        if !calendarConnection.selectedIDs.contains(id) { calendarConnection.select(id, included: true) }
        Task { await calendarConnection.refresh(day: selectedDay, settings: settings) }
    }
    func enableCalendarWriting() async {
        guard !isDemo, !enablingCalendarWriting else { return }
        enablingCalendarWriting = true; publicationSettingsError = nil
        defer { enablingCalendarWriting = false }
        do {
            try await googleCalendar.enablePublishing()
            await calendarConnection.refresh(day: selectedDay, settings: settings)
            await refreshPublishingSettings()
            await retryPendingPublications(force: true)
        } catch { publicationSettingsError = error.localizedDescription }
    }
    @discardableResult func confirmPlan(_ value: DayPlan, calendarChecked: Bool = false) async -> Bool {
        guard !publishingCalendar else { return false }
        guard !calendarEdits.contains(where: { $0.unresolved && $0.publication.day == value.id }) else { error = "Finish the pending calendar edit before confirming this day."; return false }
        var p = value
        if isDemo {
            p.status = .local
            let saved = savePlan(p, message: "Confirm example plan")
            if saved { showNotice("Example plan confirmed. Google Calendar was not changed.") }
            return saved
        }
        if !calendarChecked {
            let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone; format.dateFormat = "yyyy-MM-dd"
            guard let day = format.date(from: p.id) else { error = CalendarPublicationError.invalidPlan.localizedDescription; return false }
            let snapshot = settings, original = plans.first { $0.id == p.id }
            do {
                let meetings = try await readPlanningMeetings(day: day, settings: snapshot).blocks
                guard settings == snapshot, plans.first(where: { $0.id == p.id }) == original,
                      meetings.sorted(by: { $0.id < $1.id }) == p.blocks.filter({ $0.kind == .meeting }).sorted(by: { $0.id < $1.id }) else {
                    error = "The calendar or plan changed since this draft. Replan, review the times, and confirm again."; return false
                }
            } catch { self.error = error.localizedDescription; return false }
        }
        await refreshPublishingSettings()
        guard let destination = p.publication?.destination ?? publicationDestination else {
            error = CalendarPublicationError.destination.localizedDescription; return false
        }
        p.status = .local
        p.publication = CalendarPublication(plan: p, workspaceID: workspaceID, destination: destination, timeZone: settings.timeZone)
        guard savePlan(p, message: "Confirm plan and queue Google Calendar publication") else { return false }
        await retryPendingPublications(force: true)
        return true
    }
    func retryPendingPublications(force: Bool = false) async {
        guard !isDemo, !publishingCalendar else { return }
        await retryCalendarEdits(force: force)
        guard !publishingCalendar else { return }
        let editingDays = Set(calendarEdits.filter(\.unresolved).map { $0.publication.day })
        let pending = plans.filter { !editingDays.contains($0.id) }.compactMap(\.publication).filter { $0.state == .pending && (force || ($0.nextAttemptAt ?? .distantPast) <= Date()) }
        guard !pending.isEmpty else { return }
        publishingCalendar = true
        defer { publishingCalendar = false }
        calendarWritingAllowed = await googleCalendar.oauth.publishingAuthorized()
        for original in pending.sorted(by: { $0.day < $1.day }) {
            guard let current = plans.first(where: { $0.id == original.day })?.publication, current.id == original.id, current.state == .pending else { continue }
            var result = current
            do {
                guard calendarWritingAllowed else { throw GoogleCalendarError.publishingPermission }
                let times = try await googleCalendar.eventTimes(current, missingAllowed: true)
                guard let latest = plans.first(where: { $0.id == current.day }), latest.publication?.id == current.id else { continue }
                let update = CalendarSchedule.reconciling(latest, times: times, settings: settings, includingPending: true)
                if update.plan != latest {
                    guard savePlan(update.plan, message: "Check Google times before Calendar publication") else { return }
                    result = plans.first { $0.id == current.day }!.publication!
                    if !update.conflicts.isEmpty || result.state != .pending { continue }
                }
                try await googleCalendar.synchronize(result, expectedTimes: times)
                result.state = .published; result.known = result.desired
                result.lastPublishedEvents = result.desired
                result.missingEventIDs = nil
                result.publishedAt = Date(); result.lastError = nil; result.nextAttemptAt = nil
            } catch {
                result.attempts += 1; result.lastError = error.localizedDescription
                result.nextAttemptAt = Date().addingTimeInterval(min(900, 30 * pow(2, Double(min(5, result.attempts)))))
            }
            guard var latest = plans.first(where: { $0.id == result.day }), latest.publication?.id == result.id else { continue }
            if !result.matches(latest, timeZone: settings.timeZone) { result.state = .needsConfirmation }
            latest.publication = result
            guard savePlan(latest, message: result.state == .published ? "Record Google Calendar publication" : "Record pending Calendar publication") else { return }
        }
        calendarWritingAllowed = await googleCalendar.oauth.publishingAuthorized()
        if calendarConnection.enabled { await calendarConnection.refresh(day: selectedDay, settings: settings) }
    }
}
