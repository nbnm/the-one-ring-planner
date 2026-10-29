import SwiftUI
import RingCore

struct CalendarPublicationPanel: View {
    @EnvironmentObject var store: PlannerStore
    let plan: DayPlan
    var compact = false
    private func publishedSummary(_ publication: CalendarPublication) -> String {
        let tasks = publication.desired.filter { $0.taskID != nil }.count
        let routines = publication.desired.filter { $0.routineID != nil }.count
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks) task \(tasks == 1 ? "block" : "blocks")") }
        if routines > 0 { parts.append("\(routines) \(routines == 1 ? "routine" : "routines")") }
        return (parts.isEmpty ? "No scheduled events" : parts.joined(separator: " · ")) + " added to \(publication.destination.title)"
    }
    var body: some View {
        if compact { compactPanel }
        else { fullPanel }
    }
    private var compactPanel: some View {
        HStack {
            if let publication = plan.publication, publication.state == .pending {
                Label("Calendar sync pending", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Theme.gold)
                Spacer()
                if store.calendarWritingAllowed {
                    Button("Retry") { Task { await store.retryPendingPublications(force: true) } }.buttonStyle(.plain).disabled(store.publishingCalendar)
                } else { Button("Enable sync") { store.page = .settings }.buttonStyle(.plain) }
            } else if plan.publication?.missingEventIDs?.isEmpty == false {
                Label("Review calendar sync", systemImage: "exclamationmark.circle").foregroundStyle(Theme.alert)
                Spacer()
                Button("Calendar") { store.page = .calendar }.buttonStyle(.plain)
            } else if let publication = plan.publication, publication.state == .published, publication.matches(plan, timeZone: store.settings.timeZone), !publication.hasUnconfirmedEvents(in: plan, timeZone: store.settings.timeZone) {
                Label("Synced to calendar", systemImage: "calendar.badge.checkmark").foregroundStyle(Theme.secondary)
            } else {
                Text(plan.status == .draft ? "Draft" : "Plan ready").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Confirm plan") { store.useLocalPlan() }.buttonStyle(QuietButton()).disabled(store.publishingCalendar || store.buildingPlan)
            }
        }.font(Theme.body(11))
    }
    private var fullPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isDemo && plan.status == .local {
                Label("Example plan confirmed · Google Calendar unchanged", systemImage: "checkmark.circle").font(Theme.body(12)).foregroundStyle(Theme.green)
            } else if let publication = plan.publication, publication.state == .pending {
                Label(store.publishingCalendar ? "Adding plan events to Google Calendar…" : "Confirmed · Calendar publication pending", systemImage: "arrow.triangle.2.circlepath").font(Theme.body(12, weight: .semibold)).foregroundStyle(Theme.gold)
                if let message = publication.lastError { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    if !store.calendarWritingAllowed {
                        Button("Enable calendar writing") { Task { await store.enableCalendarWriting() } }.buttonStyle(QuietButton()).disabled(store.enablingCalendarWriting)
                    } else {
                        Button("Retry now") { Task { await store.retryPendingPublications(force: true) } }.buttonStyle(QuietButton())
                    }
                    Button("Calendar settings") { store.page = .settings }.buttonStyle(.plain).foregroundStyle(Theme.gold)
                }.disabled(store.publishingCalendar)
            } else if let missing = plan.publication?.missingEventIDs, !missing.isEmpty {
                Label("Some planner events are missing from Google Calendar.", systemImage: "exclamationmark.triangle").font(Theme.body(12)).foregroundStyle(Theme.alert)
                Text("Last saved times are kept. Restore deleted events in Google’s Trash if you want them back; other event times still sync.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            } else if let publication = plan.publication, publication.state == .published,
                      publication.matches(plan, timeZone: store.settings.timeZone) {
                Label(publishedSummary(publication), systemImage: "calendar.badge.checkmark").font(Theme.body(12)).foregroundStyle(Theme.green)
                if plan.status == .draft || publication.hasUnconfirmedEvents(in: plan, timeZone: store.settings.timeZone) {
                    Button("Confirm remaining plan") { store.useLocalPlan() }.buttonStyle(QuietButton()).disabled(store.publishingCalendar || store.buildingPlan)
                }
            } else {
                if let message = plan.publication?.lastError { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
                HStack(alignment: .center, spacing: 14) {
                    Text(plan.publication == nil ? "Confirm to add scheduled tasks and routines to your Google calendar." : "Plan changed. Confirm to update its Google Calendar events.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 4)
                    Button(store.isDemo ? "Confirm example plan" : "Confirm & add to calendar") { store.useLocalPlan() }.buttonStyle(QuietButton()).fixedSize(horizontal: false, vertical: true)
                        .disabled(store.publishingCalendar || store.buildingPlan)
                }
            }
        }
    }
}
