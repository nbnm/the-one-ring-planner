import AppKit
import SwiftUI
import UserNotifications
import RingCore

struct EventAlertSnapshot {
    let reminders: [EventReminder]
    var warning: String? = nil
}

/// Native scheduled notifications continue to work with the planner window closed.
/// Only this feature's request IDs are reconciled; other notifications are untouched.
@MainActor final class EventAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "eventAlerts.enabled")
        if oldValue != enabled { Task { await refresh(requestPermission: enabled) } }
    } }
    @Published var sound: Bool { didSet {
        defaults.set(sound, forKey: "eventAlerts.sound")
        if oldValue != sound { scheduled = [:]; refreshSoon() }
    } }
    @Published private(set) var status = "Checking notification access…"
    @Published private(set) var detail: String?
    @Published private(set) var denied = false
    @Published private(set) var awaitingPermission = false
    @Published private(set) var scheduledCount = 0
    @Published private(set) var refreshing = false
    var source: (() async throws -> EventAlertSnapshot)?
    var openCalendar: ((Date) -> Void)?
    private let defaults: UserDefaults
    private let demo: Bool
    private var center: UNUserNotificationCenter { .current() }
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var scheduled: [String: EventReminder] = [:]
    private var queued = false
    private var started = false

    init(defaults: UserDefaults, demo: Bool) {
        self.defaults = defaults; self.demo = demo
        enabled = defaults.object(forKey: "eventAlerts.enabled") as? Bool ?? true
        sound = defaults.object(forKey: "eventAlerts.sound") as? Bool ?? true
        super.init()
        if demo { status = "Example mode · notifications are not sent" }
    }
    func start() {
        guard !started, !demo else { return }; started = true
        center.delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh(requestPermission: true) }
    }
    func refreshSoon() {
        guard started else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
    func refresh(requestPermission: Bool = false) async {
        guard !demo else { return }
        guard !refreshing else { queued = true; return }
        refreshing = true
        defer {
            refreshing = false
            if queued { queued = false; refreshSoon() }
        }
        if !enabled {
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("ring.event.") }.map(\.identifier))
            scheduled = [:]; scheduledCount = 0; status = "Event alerts are off"; detail = nil
            return
        }
        var permission = await center.notificationSettings()
        if permission.authorizationStatus == .notDetermined && requestPermission {
            awaitingPermission = true; status = "Allow notifications in the macOS prompt"
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { detail = error.localizedDescription }
            awaitingPermission = false
            permission = await center.notificationSettings()
        }
        denied = permission.authorizationStatus == .denied
        guard permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else {
            status = denied ? "Notifications are blocked in macOS" : "Allow notifications to enable alerts"
            scheduledCount = 0; return
        }
        guard let source else { return }
        do {
            let snapshot = try await source()
            guard enabled else { queued = true; return }
            let desired = Dictionary(uniqueKeysWithValues: snapshot.reminders.map { ($0.id, $0) })
            let pending = await center.pendingNotificationRequests()
            let obsolete = pending.filter { $0.identifier.hasPrefix("ring.event.") && desired[$0.identifier] == nil }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            let pendingIDs = Set(pending.map(\.identifier))
            for reminder in snapshot.reminders {
                guard scheduled[reminder.id] != reminder || !pendingIDs.contains(reminder.id) else { continue }
                // A range read can take time; never deliver an old one-minute warning late.
                let delay = reminder.fireDate.timeIntervalSinceNow
                guard delay > 0 else { continue }
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.subtitle = "Starts in 1 minute · \(reminder.kind)"
                let format = DateFormatter(); format.timeStyle = .short
                content.body = "\(format.string(from: reminder.start))–\(format.string(from: reminder.end))"
                content.sound = sound ? .default : nil
                content.userInfo = ["ringStart": reminder.start.timeIntervalSince1970]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
            scheduled = desired
            scheduledCount = (await center.pendingNotificationRequests()).filter { $0.identifier.hasPrefix("ring.event.") }.count
            status = "Alerts 1 minute before events"
            detail = snapshot.warning ?? (permission.alertSetting == .disabled ? "Banners are disabled in macOS Notification Settings." : nil)
        } catch {
            status = "Alerts need attention"
            detail = "Previously scheduled alerts are kept. \(error.localizedDescription)"
        }
    }
    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let stamp = response.notification.request.content.userInfo["ringStart"] as? Double
        Task { @MainActor in if let stamp { self.openCalendar?(Date(timeIntervalSince1970: stamp)) } }
        completionHandler()
    }
}

struct EventAlertSettingsSection: View {
    @ObservedObject var alerts: EventAlerts
    var body: some View {
        Section("Event alerts") {
            Toggle("Notify me 1 minute before events", isOn: $alerts.enabled)
            Toggle("Play an alert sound", isOn: $alerts.sound).disabled(!alerts.enabled)
            Text(alerts.status).font(Theme.body(12))
            if alerts.enabled && alerts.scheduledCount > 0 { Text("\(alerts.scheduledCount) upcoming alerts scheduled").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if let detail = alerts.detail { Text(detail).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            DetailNote("Alert details", "For selected Google calendars and confirmed tasks and routines. All-day events and unconfirmed drafts are excluded. Click an alert to open its day. Keep the planner running in the menu bar to receive schedule changes; macOS Focus can silence alerts.")
            HStack {
                Button("Notification settings…") { alerts.openSystemSettings() }
                Button(alerts.refreshing ? "Checking…" : "Check alerts") { Task { await alerts.refresh(requestPermission: true) } }.disabled(alerts.refreshing || !alerts.enabled)
            }
        }
    }
}
