import SwiftUI
import RingCore

/// A quiet, persistent home for sync, save and planning messages.
struct PlannerStatusBar: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var alerts: EventAlerts
    @State private var showingDetails = false
    private struct Issue: Identifiable {
        let title: String
        let detail: String
        let page: PlannerStore.Page
        var id: String { title + detail }
    }
    private var issues: [Issue] {
        var values: [Issue] = []
        func add(_ title: String, _ detail: String?, _ page: PlannerStore.Page) {
            if let detail, !detail.isEmpty, !values.contains(where: { $0.detail == detail }) {
                values.append(Issue(title: title, detail: detail, page: page))
            }
        }
        add("Inbox needs attention", store.sharedInbox.error, .inbox)
        add("Inbox AI needs attention", store.sharedInbox.jobs.first(where: { $0.lastError != nil })?.lastError, .inbox)
        add("Library needs attention", store.library.error, .library)
        add("Library AI needs attention", store.library.jobs.first(where: { $0.lastError != nil })?.lastError, .settings)
        add("Telegram needs attention", store.telegram.error, .settings)
        add("Telegram alerts need attention", store.telegram.notificationError, .settings)
        add("Telegram capture needs attention", store.telegram.state.jobs.first(where: { $0.lastError != nil })?.lastError, .settings)
        add("Telegram send needs attention", store.telegram.state.outbox.first(where: { $0.lastError != nil })?.lastError, .settings)
        add("Data backup needs attention", store.library.backupState.lastError, .settings)
        add("Calendar sync needs attention", store.calendarScheduleError, .calendar)
        add("Calendar could not load", store.calendarDisplayError, .calendar)
        add("Calendar connection needs attention", store.calendarConnection.message, .settings)
        add("Calendar settings need attention", store.publicationSettingsError, .settings)
        if store.calendarPlanNeedsRefresh { add("Calendar changed", "Replan this day to account for the latest calendar events.", .today) }
        if let publication = store.plan?.publication {
            add("Calendar publication needs attention", publication.lastError, .today)
            if publication.missingEventIDs?.isEmpty == false {
                let count = publication.missingEventIDs!.count
                add("Calendar events are missing", "\(count) \(count == 1 ? "event is" : "events are") missing from Google Calendar. Restore \(count == 1 ? "it" : "them") in Google’s Trash if you want \(count == 1 ? "it" : "them") back.", .calendar)
            }
        }
        for edit in store.calendarEdits where edit.unresolved {
            add("Calendar change needs attention", edit.lastError, .calendar)
        }
        for warning in store.displayPlan?.warnings ?? [] { add("Plan conflict", warning, .today) }
        if alerts.enabled {
            if alerts.awaitingPermission { add("Allow event notifications", "Choose Allow in the macOS notification prompt to receive alerts one minute before events.", .settings) }
            else if alerts.denied { add("Event alerts are blocked", "Allow The One Ring Planner in macOS Notification Settings.", .settings) }
            else { add("Event alerts need attention", alerts.detail, .settings) }
        }
        if store.repository == nil { add("Saving is unavailable", "Open Settings to check the local workspace.", .settings) }
        return values
    }
    private var busy: Bool { store.buildingPlan || store.publishingCalendar || store.calendarEditSending || store.syncingCalendarSchedule || store.calendarConnection.loading }
    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.mini).accessibilityLabel("Syncing") }
            else { Image(systemName: issues.isEmpty ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(issues.isEmpty ? Theme.secondary : Theme.alert) }
            if let notice = store.notice {
                Text(notice).lineLimit(1).help(notice)
            } else if !issues.isEmpty {
                Button(issues.first!.title) { showingDetails.toggle() }.buttonStyle(.plain).foregroundStyle(Theme.alert).lineLimit(1)
            } else {
                Text(busy ? "Syncing…" : (store.isDemo ? "Example workspace" : "Saved on this Mac")).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 12)
            if !issues.isEmpty {
                Button { showingDetails.toggle() } label: {
                    Label("\(issues.count)", systemImage: "exclamationmark.triangle")
                }.buttonStyle(.plain).foregroundStyle(Theme.alert).help("View messages and warnings").accessibilityLabel("Show \(issues.count) status messages")
            }
            Button { store.page = .settings } label: {
                Image(systemName: store.calendarConnection.connected ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                    .foregroundStyle(store.calendarConnection.connected ? Theme.green : Theme.secondary)
            }.buttonStyle(.plain).help(store.calendarConnection.status).accessibilityLabel(store.calendarConnection.status)
            if store.meetings.activeID != nil {
                Button { store.page = .meetings } label: { Label("Recording", systemImage: "record.circle.fill").foregroundStyle(Theme.calendarTask) }.buttonStyle(.plain)
            }
        }
        .font(Theme.body(10)).padding(.horizontal, 16).frame(height: 30)
        .background(Theme.statusSurface.opacity(0.6)).overlay(alignment: .top) { DividerLine() }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Status").font(Theme.body(14, weight: .semibold)); Spacer(); Button { showingDetails = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close status messages") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { showingDetails = false; store.page = issue.page } label: { HStack { Text(issue.title).font(Theme.body(12, weight: .semibold)); Spacer(); Image(systemName: "arrow.up.right") } }.buttonStyle(.plain).foregroundStyle(Theme.gold)
                                Text(issue.detail).font(Theme.body(12)).foregroundStyle(Theme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.frame(maxHeight: 330)
            }.padding(20).frame(width: 440).background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }
}

/// Supporting explanations stay available without occupying the working screen.
struct DetailNote: View {
    let title: String
    let text: String
    init(_ title: String = "Details", _ text: String) { self.title = title; self.text = text }
    var body: some View {
        DisclosureGroup(title) { Text(text).font(Theme.body(11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6) }
            .font(Theme.body(11)).foregroundStyle(Theme.secondary)
    }
}
