import SwiftUI
import RingCore

struct TelegramSettingsSection: View {
    @ObservedObject var telegram: TelegramStore
    @State private var preferences = TelegramPollingSettings()
    @State private var token = ""
    @State private var replaceWebhook = false
    @State private var confirmRetrySends = false
    var body: some View {
        Section("Telegram") {
            LabeledContent("Bot", value: telegram.status)
            if let error = telegram.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled) }
            if let warning = telegram.notificationError { Text(warning).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            DisclosureGroup("Connection") {
                SecureField(telegram.settings.botID == nil ? "Bot token" : "Replace saved bot token", text: $token).accessibilityLabel("Telegram bot token")
                if telegram.needsWebhookReplacement { Toggle("Replace the bot's existing webhook", isOn: $replaceWebhook) }
                Button(telegram.connecting ? "Connecting…" : "Connect bot") {
                    let credential = token; token = ""
                    Task { await telegram.connect(token: credential, preferences: preferences, replaceWebhook: replaceWebhook); preferences = telegram.settings }
                }.disabled(telegram.demo || telegram.connecting || (!preferences.isValid) || (token.isEmpty && telegram.settings.botID == nil))
                if telegram.state.ownerID == nil, telegram.settings.botID != nil {
                    if let code = telegram.pairingCode {
                        HStack { Text("/pair " + code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled); CopyTextIcon(text: "/pair " + code, label: "Copy Telegram pairing command") }
                        Text("Send this command to @\(telegram.settings.username) in a private chat within 10 minutes.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                    }
                    Button("New pairing code") { telegram.makePairingCode() }
                }
                if let owner = telegram.state.ownerID { LabeledContent("Paired private chat", value: String(owner)) }
                DisclosureGroup("Setup") {
                    Text("Use a dedicated bot from @BotFather. Paste its token here, connect, then send the pairing command in your private chat. Other senders and groups are ignored. Polling runs while the app is open, including with its window closed; this Mac must be awake. Telegram keeps undelivered updates for up to 24 hours.").font(Theme.body(11))
                    Text("Voice notes use your saved LiteLLM gateway and FFmpeg on this Mac. Original audio is stored with the Inbox capture and included in data backups. Files are limited to 20 MB; audio can be up to two hours.").font(Theme.body(11))
                }
            }
            DisclosureGroup("Appearance") {
                Button(telegram.updatingIdentity ? "Updating profile…" : "Update bot profile") { Task { await telegram.updateIdentity() } }.disabled(telegram.demo || telegram.settings.botID == nil || telegram.updatingIdentity)
                Button("Send message preview") { Task { await telegram.sendMessagePreview() } }.disabled(telegram.demo || !telegram.settings.enabled || telegram.state.ownerID == nil)
                if let status = telegram.identityStatus { Text(status).font(Theme.body(11)).foregroundStyle(Theme.green) }
                Text("Ring avatar, app name and English/Russian profile descriptions.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            }
            Toggle("Background polling", isOn: $preferences.enabled)
            Stepper("Poll every \(preferences.interval) seconds", value: $preferences.interval, in: 5...300, step: 5)
            DisclosureGroup("Voice notes") {
                TextField("Transcription model (blank uses The Eye model)", text: $preferences.audioModel)
                Toggle("Split independent tasks into Inbox suggestions", isOn: $preferences.splitAudio)
            }
            DisclosureGroup("Digests & alerts") {
                Toggle("Daily plan digest", isOn: $preferences.dailyDigest)
                if preferences.dailyDigest { MinutePicker(title: "Send after", minute: $preferences.digestMinute) }
                Toggle("Notify about new Q1 tasks", isOn: $preferences.urgentAlerts)
                Toggle("Event alerts · 1 minute before", isOn: $preferences.eventAlerts)
                if preferences.eventAlerts && preferences.interval > 30 { Text("Event alerts require polling every 30 seconds or faster.").font(Theme.body(11)).foregroundStyle(Theme.alert) }
            }
            HStack {
                Button("Save Telegram preferences") { Task { await telegram.savePreferences(preferences) } }.disabled(telegram.demo || telegram.settings.botID == nil || !preferences.isValid)
                Button("Poll now") { Task { await telegram.pollNow() } }.disabled(!telegram.settings.enabled || telegram.polling || telegram.demo)
            }
            if !telegram.state.jobs.isEmpty || !telegram.state.outbox.isEmpty {
                DisclosureGroup("Pending & recovery · \(telegram.state.jobs.count) captures, \(telegram.state.outbox.count) sends") {
                    ForEach(telegram.state.jobs.filter { $0.lastError != nil }) { job in Text("\(job.update.message?.content.prefix(80) ?? "Capture") · \(job.lastError ?? "")").font(Theme.body(11)).foregroundStyle(Theme.alert) }
                    Button("Retry captures") { telegram.retryCaptures() }
                    ForEach(telegram.state.outbox.filter { $0.attemptedAt != nil }) { item in Text(item.lastError ?? "Delivery was not confirmed. Retrying may send a duplicate.").font(Theme.body(11)).foregroundStyle(Theme.alert) }
                    Button("Retry unconfirmed sends…") { confirmRetrySends = true }.disabled(!telegram.state.outbox.contains { $0.attemptedAt != nil })
                }
            }
            DisclosureGroup("Commands & diagnostics") {
                Text(TelegramCommands.help).font(Theme.body(11)).textSelection(.enabled)
                if let date = telegram.lastPoll { LabeledContent("Last successful poll", value: date.formatted()) }
                LabeledContent("Pending captures", value: String(telegram.state.jobs.count))
            }
        }
        .onAppear { preferences = telegram.settings }
        .confirmationDialog("Retry sends? A message may arrive twice if Telegram received it but its response was lost.", isPresented: $confirmRetrySends) { Button("Retry sends") { telegram.retrySends() }; Button("Cancel", role: .cancel) {} }
    }
}
