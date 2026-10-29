import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RingCore

struct CalendarSettingsSection: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var connection: CalendarConnection
    @State private var clientID: String?
    @State private var configurationMessage: String?
    @State private var setup = false
    var body: some View {
        Section("Google Calendar · direct connection") {
            LabeledContent("Connection", value: connection.status)
            DetailNote("Connection details", "Sign in directly with Google. Your selected calendars are read from the Google Calendar API, and their busy time is reserved in new drafts.")
            if clientID == nil {
                Text("Set up Google sign-in once, then import the Desktop app credentials.").font(Theme.body(12, weight: .semibold))
            } else {
                LabeledContent("OAuth client", value: "Desktop app configured").font(Theme.body(11))
            }
            HStack(spacing: 14) {
                Button("Setup guide") { setup = true }
                Button(clientID == nil ? "Import OAuth credentials…" : "Replace OAuth credentials…") { importCredentials() }.disabled(connection.loading || store.isDemo)
                Spacer()
            }
            HStack(spacing: 14) {
                Button(connection.access == .full ? "Switch Google account" : "Sign in with Google") {
                    Task {
                        if connection.enabled { await connection.disconnect() }
                        await connection.connect(day: store.selectedDay, settings: store.settings)
                    }
                }.disabled(connection.loading || store.isDemo || clientID == nil).accessibilityLabel("Sign in directly with Google")
                if connection.enabled && connection.access == .full {
                    Button("Refresh calendars") { Task { await connection.refresh(day: store.selectedDay, settings: store.settings) } }.disabled(connection.loading)
                }
                if connection.loading { ProgressView().controlSize(.small) }
                Spacer()
                if connection.loading { Button("Cancel") { Task { await connection.cancelCheck() } } }
                else if connection.enabled { Button("Disconnect") { Task { await connection.disconnect() } } }
            }
            if store.isDemo { Text("Google sign-in is available in your normal workspace. Example mode keeps real events private.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if let message = configurationMessage ?? connection.message {
                Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true)
            }
            if connection.enabled && connection.access == .full {
                if connection.calendars.isEmpty {
                    Text("Google returned no readable calendars. Check the signed-in account and refresh.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
                } else {
                    Text("Include in your day").font(Theme.body(12, weight: .semibold))
                    ForEach(connection.calendars) { calendar in
                        Toggle(isOn: Binding(get: { connection.selectedIDs.contains(calendar.id) }, set: { selected in
                            connection.select(calendar.id, included: selected)
                            Task { await connection.refresh(day: store.selectedDay, settings: store.settings, refreshSources: false) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calendar.title).font(Theme.body(12))
                                Text(calendar.account).font(Theme.body(10)).foregroundStyle(Theme.secondary)
                            }
                        }.toggleStyle(.checkbox).accessibilityLabel("Include \(calendar.title) from \(calendar.account)")
                    }
                }
                if connection.hasMissingCalendars {
                    Text("A selected Google calendar is unavailable. Refresh or remove the unavailable selection.").font(Theme.body(11)).foregroundStyle(Theme.alert)
                    Button("Clear missing calendars") { connection.clearMissingCalendars(); Task { await connection.refresh(day: store.selectedDay, settings: store.settings) } }
                }
            }
            if let date = connection.lastRead {
                Text("Last read from Google: \(date.formatted(date: .abbreviated, time: .shortened)).").font(Theme.body(10)).foregroundStyle(Theme.secondary)
            }
            if store.syncingCalendarSchedule { Text("Syncing planner event times…").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if let message = store.calendarScheduleError { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            Divider()
            Text("Confirmed plan → Google Calendar").font(Theme.body(13, weight: .semibold))
            DetailNote("How calendar sync works", "Scheduled tasks and routines become private busy events, without guests or notifications. Save draft keeps the plan local. Reconfirming updates the planner’s events and removes blocks dropped from the confirmed plan.")
            HStack(spacing: 20) {
                Label("Tasks · Red", systemImage: "circle.fill").foregroundStyle(Theme.calendarTask)
                Label("Routine activities · Green", systemImage: "circle.fill").foregroundStyle(Theme.calendarRoutine)
            }.font(Theme.body(11, weight: .semibold))
            if !store.publicationDestinations.isEmpty {
                Picker("Publish confirmed plans to", selection: Binding(get: { store.publicationDestination?.id ?? "" }, set: { store.selectPublicationCalendar($0) })) {
                    ForEach(store.publicationDestinations) { Text($0.title).tag($0.id) }
                }
                DetailNote("Calendar selection details", "Use a calendar you own. Changing this choice affects new days; existing plans keep their original calendar.")
            }
            if store.calendarWritingAllowed { Label("Calendar writing enabled", systemImage: "checkmark.circle").font(Theme.body(12)).foregroundStyle(Theme.green) }
            else {
                Button(store.enablingCalendarWriting ? "Waiting for Google…" : "Enable calendar writing") { Task { await store.enableCalendarWriting() } }
                    .disabled(store.isDemo || store.enablingCalendarWriting || connection.loading || clientID == nil)
                DetailNote("Calendar access details", "Google will ask for permission to create and change events on calendars you own. Existing read access continues to work if you cancel.")
            }
            if store.enablingCalendarWriting { Button("Cancel Google sign-in") { Task { await store.googleCalendar.cancelAuthorization() } } }
            if let message = store.publicationSettingsError { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            Button(store.updatingCalendarColors ? "Updating event colors…" : "Apply colors to existing events") { Task { await store.applyCalendarColors() } }
                .disabled(store.isDemo || !store.calendarWritingAllowed || store.publishingCalendar || store.enablingCalendarWriting || connection.loading)
            DetailNote("Event and key details", "Updates only colors on existing planner events. Their times and details stay as they are.")
            if let message = store.calendarColorNotice { Text(message).font(Theme.body(11)).foregroundStyle(Theme.green) }
            if let message = store.calendarColorError { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            DetailNote("Saved keys", "Tokens and client credentials stay in Keychain. If macOS asks during the signing upgrade, choose Always Allow to remember this app. Future updates keep the same app identity. The planner changes only events marked as belonging to this workspace.")
        }
        .task { do { clientID = try await store.googleCalendar.clientID(); await store.refreshPublishingSettings() } catch { configurationMessage = error.localizedDescription } }
        .onChange(of: connection.calendars) { _, _ in Task { await store.refreshPublishingSettings() } }
        .onChange(of: connection.enabled) { _, enabled in if !enabled { store.calendarWritingAllowed = false; store.publicationDestinations = [] } }
        .sheet(isPresented: $setup) { GoogleCalendarSetupGuide() }
    }
    private func importCredentials() {
        let panel = NSOpenPanel(); panel.title = "Import Google Desktop app OAuth credentials"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65_536 else { throw GoogleCalendarError.configuration }
                    let data = try Data(contentsOf: url)
                    _ = try GoogleOAuthConfiguration.imported(data)
                    await connection.disconnect()
                    try await store.googleCalendar.configure(data)
                    clientID = try await store.googleCalendar.clientID(); configurationMessage = nil
                } catch { configurationMessage = error.localizedDescription }
            }
        }
    }
}

private struct GoogleCalendarSetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect directly to Google").font(Theme.display(28))
            Text("One-time setup for this personal build").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            Text("1. Create or select a Google Cloud project. Enable the Google Calendar API.")
            Text("2. Configure Google Auth Platform with the app name The One Ring Planner and your support email. Choose Internal for your Workspace organization, or External with your own email as a test user.")
            Text("3. Create an OAuth client. Choose Desktop app and name it The One Ring Planner. Download its JSON credentials.")
            Text("4. Return here, import that JSON, then choose Sign in with Google. Allow the two calendar read permissions and select your calendars.")
            Text("5. To publish scheduled tasks and routines, choose Enable calendar writing in Settings and approve Google's additional event permission. Select a calendar you own.")
            Text("External apps in Testing may need a new sign-in after seven days. Workspace administrators may need to permit the app.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            HStack(spacing: 14) {
                Button("Enable Calendar API") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!) }
                Button("OAuth clients") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/auth/clients")!) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(Theme.body(13)).lineSpacing(3).padding(30).frame(width: 640).foregroundStyle(Theme.text).background(Theme.background)
    }
}

struct CalendarStatusButton: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var connection: CalendarConnection
    var body: some View {
        Button { store.page = .calendar } label: {
            Label(connection.status, systemImage: connection.connected ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .font(Theme.body(11)).foregroundStyle(connection.connected ? Theme.green : Theme.secondary)
        }.buttonStyle(.plain).help("Open calendars and connection status")
    }
}

struct CalendarAgenda: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var connection: CalendarConnection
    var compact = true
    private var events: [CalendarOccurrence] { compact ? Array(connection.events.prefix(4)) : connection.events }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                HStack { SectionLabel(title: "From your calendars"); Spacer(); Button("View all") { store.page = .calendar }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold) }
            }
            if connection.loading { HStack { ProgressView().controlSize(.small); Text("Reading selected calendars…").font(Theme.body(12)) } }
            else if !connection.connected {
                Text(connection.message ?? "Choose the calendars to include in Settings.").font(Theme.body(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Calendar settings") { store.page = .settings }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold)
            } else if connection.events.isEmpty {
                Text("No events in your selected calendars for this day.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            }
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 14) {
                    Text(event.allDay ? "All day" : store.time(event.start)).font(Theme.body(11, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 50, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(Theme.body(13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(event.calendarTitle + (event.allDay ? " · All day" : " · \(store.time(event.start))–\(store.time(event.end))")).font(Theme.body(10)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(eventLabel(event)).font(Theme.body(10)).foregroundStyle(eventTint(event))
                }
            }
            if store.calendarPlanNeedsRefresh {
                HStack { Text("Calendar events changed since this draft.").font(Theme.body(11)).foregroundStyle(Theme.alert); Spacer(); Button("Replan") { store.generate() }.buttonStyle(QuietButton()).disabled(store.buildingPlan) }
            }
            if compact { DividerLine() }
        }
    }
    private func eventLabel(_ event: CalendarOccurrence) -> String {
        switch event.plannerCategory {
        case .task: return event.colorID == PlannerCalendarCategory.task.googleColorID ? "Task · Red" : "Planner task"
        case .routine: return event.colorID == PlannerCalendarCategory.routine.googleColorID ? "Routine · Green" : "Routine"
        case nil: return event.managedByPlanner ? "Planner event" : (event.busy ? "Busy" : "Free")
        }
    }
    private func eventTint(_ event: CalendarOccurrence) -> Color {
        if let category = event.plannerCategory, event.colorID == category.googleColorID {
            return category == .task ? Theme.calendarTask : Theme.calendarRoutine
        }
        return event.busy ? Theme.gold : Theme.secondary
    }
}
