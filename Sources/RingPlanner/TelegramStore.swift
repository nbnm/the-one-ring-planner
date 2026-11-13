import SwiftUI
import RingCore

/// Direct Bot API polling. All cursors, pending jobs and delivery checkpoints stay outside the backed-up Data tree.
@MainActor final class TelegramStore: ObservableObject {
    let repository: DataRepository?
    let ai: CaptureAISettings
    let inbox: SharedInboxStore
    let demo: Bool
    @Published var settings = TelegramPollingSettings()
    @Published var state = TelegramPollingState()
    @Published var error: String?
    @Published var notificationError: String?
    @Published var lastPoll: Date?
    @Published var pairingCode: String?
    @Published var pairingExpiry: Date?
    @Published var updatingIdentity = false
    @Published var identityStatus: String?
    @Published var connecting = false
    @Published var polling = false
    @Published var processing = false
    @Published var needsWebhookReplacement = false
    var command: (String) -> String = { _ in "Planner is starting. Try again shortly." }
    var digest: (Date) -> String = { _ in "No plan available." }
    var urgent: () -> [PlannerTask] = { [] }
    var reminders: () async throws -> [EventReminder] = { [] }
    var defaultAudioModel: () -> String = { "" }
    private var ticker: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var nextPoll = Date.distantPast
    private var nextReminders = Date.distantPast
    private var cachedReminders: [EventReminder] = []
    private var generation = UUID()
    private var sending = false
    private var client: TelegramBotClient?
    var status: String {
        if demo { return "Example mode" }
        guard settings.botID != nil else { return "Not connected" }
        if !settings.enabled { return "Polling paused" }
        return state.ownerID == nil ? "Waiting for pairing" : "Connected · @\(settings.username)"
    }
    init(repository: DataRepository?, ai: CaptureAISettings, inbox: SharedInboxStore, demo: Bool) {
        self.repository = repository; self.ai = ai; self.inbox = inbox; self.demo = demo
        if let repository {
            settings = (try? LibraryStore.read(TelegramPollingSettings.self, file: repository.localState.appendingPathComponent("telegram-polling.json"))) ?? TelegramPollingSettings()
            if let id = settings.botID {
                do { state = try LibraryStore.read(TelegramPollingState.self, file: repository.localState.appendingPathComponent("telegram-polling-\(id).json")) }
                catch { if FileManager.default.fileExists(atPath: repository.localState.appendingPathComponent("telegram-polling-\(id).json").path) { settings.enabled = false; self.error = "Telegram's local cursor could not be read. Its file is preserved. Restore it before reconnecting to avoid duplicate captures." } }
            }
        }
    }
    private func saveState(_ value: TelegramPollingState) throws {
        guard let repository, let id = settings.botID else { throw LibraryError.invalid("Telegram storage is unavailable.") }
        try LibraryStore.write(value, file: repository.localState.appendingPathComponent("telegram-polling-\(id).json")); state = value
    }
    private func persist() throws { try saveState(state) }
    func connect(token raw: String, preferences: TelegramPollingSettings, replaceWebhook: Bool) async {
        guard !demo, !connecting, let repository, preferences.isValid else { return }
        connecting = true; defer { connecting = false }
        do {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = token.isEmpty ? try await ai.secret(account: "telegram-direct-bot-token") : token
            let candidate = try TelegramBotClient(token: credential), me = try await candidate.me()
            guard me.is_bot == true, let username = me.username else { throw TelegramBotError.configuration("Use a Telegram bot token from @BotFather.") }
            if try await candidate.webhookConfigured() {
                guard replaceWebhook else { needsWebhookReplacement = true; throw TelegramBotError.configuration("This bot currently uses a webhook. Select Replace webhook to switch it to polling without dropping pending messages.") }
                try await candidate.removeWebhook()
            }
            await stop()
            try ai.saveSecret(credential, account: "telegram-direct-bot-token")
            var config = preferences; config.botID = me.id; config.username = username; config.enabled = true
            var loaded = TelegramPollingState()
            let file = repository.localState.appendingPathComponent("telegram-polling-\(me.id).json")
            if FileManager.default.fileExists(atPath: file.path) { loaded = try LibraryStore.read(TelegramPollingState.self, file: file) }
            try LibraryStore.write(config, file: repository.localState.appendingPathComponent("telegram-polling.json"))
            settings = config; state = loaded; client = candidate; error = nil; needsWebhookReplacement = false
            try persist()
            if state.ownerID == nil { makePairingCode() }
            try? await candidate.setCommands()
            start()
        } catch { self.error = safeError(error) }
    }
    func savePreferences(_ preferences: TelegramPollingSettings) async {
        guard let repository, preferences.isValid else { error = "Choose polling from 5–300 seconds. Event alerts require 30 seconds or faster."; return }
        do {
            var value = preferences; value.botID = settings.botID; value.username = settings.username
            try LibraryStore.write(value, file: repository.localState.appendingPathComponent("telegram-polling.json")); settings = value; error = nil
            if value.enabled { nextPoll = .distantPast; start() } else { await stop() }
        } catch { self.error = safeError(error) }
    }
    func sendMessagePreview() async {
        guard !demo, settings.enabled, state.ownerID != nil else { return }
        do {
            state.queue(id: "appearance-preview:" + UUID().uuidString, text: TelegramMessageStyle.preview)
            try persist(); await pollNow()
        } catch { self.error = safeError(error) }
    }
    func updateIdentity() async {
        guard !demo, !updatingIdentity, settings.botID != nil else { return }
        updatingIdentity = true; identityStatus = nil; defer { updatingIdentity = false }
        do {
            guard let avatar = Bundle.main.url(forResource: "TelegramAvatar", withExtension: "jpg") ?? Bundle.module.url(forResource: "TelegramAvatar", withExtension: "jpg") else { throw TelegramBotError.configuration("The bot avatar is missing from this build.") }
            let token = try await ai.secret(account: "telegram-direct-bot-token")
            let result = try await TelegramBotClient(token: token).applyIdentity(avatarJPEG: Data(contentsOf: avatar))
            guard result.name == TelegramIdentity.name else { throw TelegramBotError.invalidResponse }
            identityStatus = "Bot profile updated"
            if let repository { try LibraryStore.write(["name": result.name, "photoFileID": result.photoFileID, "updatedAt": ISO8601DateFormatter().string(from: Date())], file: repository.localState.appendingPathComponent("telegram-identity.json")) }
        } catch { self.error = safeError(error) }
    }
    func makePairingCode() {
        guard state.ownerID == nil, settings.botID != nil else { return }
        pairingCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); pairingExpiry = Date().addingTimeInterval(600)
    }
    func start() {
        guard !demo, settings.enabled, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date() >= self.nextPoll { await self.pollNow() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func stop() async {
        generation = UUID(); ticker?.cancel(); worker?.cancel()
        let oldTicker = ticker, oldWorker = worker; ticker = nil; worker = nil
        await oldTicker?.value; await oldWorker?.value
        client = nil; polling = false; processing = false; nextPoll = .distantPast
    }
    func pollNow() async {
        guard !demo, settings.enabled, !polling, let botID = settings.botID else { return }
        polling = true; let current = generation
        defer { polling = false }
        do {
            let active: TelegramBotClient
            if let client { active = client } else { active = try TelegramBotClient(token: await ai.secret(account: "telegram-direct-bot-token")); client = active }
            let updates = try await active.updates(offset: state.offset)
            guard current == generation, !Task.isCancelled else { return }
            if pairingExpiry.map({ $0 <= Date() }) == true { pairingCode = nil; pairingExpiry = nil }
            var next = state
            for update in updates where update.update_id >= next.offset {
                if next.ownerID == nil, let message = update.message, TelegramPairing.matches(message, code: pairingCode, expires: pairingExpiry, now: Date()) {
                    next.ownerID = message.chat.id; next.offset = update.update_id + 1
                    next.queue(id: "paired:\(update.update_id)", text: "Paired with The One Ring Planner. Send a message, file or voice note to Inbox. /help")
                } else { try next.receive([update]) }
            }
            next.prune(now: Date()); try saveState(next)
            if state.ownerID != nil { pairingCode = nil; pairingExpiry = nil }
            lastPoll = Date(); nextPoll = Date().addingTimeInterval(Double(settings.interval)); error = nil
            if state.ownerID != nil {
                for job in state.jobs where job.update.message?.text?.hasPrefix("/") == true {
                    if let owner = state.ownerID, job.update.message?.belongs(to: owner) == true { state.queue(id: "reply:\(job.id)", text: command(job.update.message!.text!)) }
                    state.jobs.removeAll { $0.id == job.id }
                }
                try persist()
                do { try await scheduleNotifications(); notificationError = nil } catch { notificationError = "Telegram alerts: " + safeError(error) }
                try await flushOutbox(using: active, generation: current)
                startWorker(client: active, botID: botID, generation: current)
            }
        } catch {
            if !Task.isCancelled, current == generation { self.error = safeError(error); nextPoll = Date().addingTimeInterval(Double((error as? TelegramBotError)?.retryAfter ?? 30)) }
        }
    }
    private func startWorker(client: TelegramBotClient, botID: Int64, generation current: UUID) {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            processing = true
            defer { processing = false; worker = nil }
            while !Task.isCancelled, current == generation, settings.enabled {
                let available = state.jobs.filter { ($0.nextAttempt ?? .distantPast) <= Date() }
                guard let job = available.first(where: { $0.update.message?.text?.hasPrefix("/") == true }) ?? available.first else { return }
                do {
                    guard let message = job.update.message, let owner = state.ownerID, message.belongs(to: owner) else { throw TelegramBotError.configuration("The queued message does not belong to the paired private chat.") }
                    if let text = message.text, text.hasPrefix("/") {
                        state.queue(id: "reply:\(job.id)", text: command(text))
                    } else { try await importMessage(job, client: client, botID: botID, owner: owner, generation: current) }
                    try Task.checkCancellation(); guard current == generation else { return }
                    state.jobs.removeAll { $0.id == job.id }; try persist()
                    try await flushOutbox(using: client, generation: current)
                } catch {
                    if Task.isCancelled || current != generation { return }
                    if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
                        state.jobs[index].attempts += 1; state.jobs[index].lastError = safeError(error)
                        let transient: Bool = error is URLError || { if case TelegramBotError.network = error { return true }; if case TelegramBotError.http(let code, _) = error { return code == 429 || code >= 500 }; return false }()
                        state.jobs[index].nextAttempt = transient && state.jobs[index].attempts < 4 ? Date().addingTimeInterval(Double((error as? TelegramBotError)?.retryAfter ?? 60)) : .distantFuture
                        state.queue(id: "failure:\(job.id)", text: "This capture needs attention in the app's Telegram settings. It is kept for retry. " + safeError(error))
                    }
                    do { try persist() } catch { self.error = "Telegram queue could not be saved. Polling is paused; your files are preserved."; settings.enabled = false; return }
                }
            }
        }
    }
    func retryCaptures() {
        for index in state.jobs.indices { state.jobs[index].attempts = 0; state.jobs[index].nextAttempt = nil; state.jobs[index].lastError = nil }
        do { try persist(); nextPoll = .distantPast } catch { self.error = safeError(error) }
    }
    func retrySends() {
        for index in state.outbox.indices { state.outbox[index].attemptedAt = nil; state.outbox[index].lastError = nil }
        do { try persist(); nextPoll = .distantPast } catch { self.error = safeError(error) }
    }
    func safeError(_ error: Error) -> String {
        if let error = error as? TelegramBotError { return error.localizedDescription }
        if error is URLError { return "The network request failed. Saved captures can be retried." }
        if let failure = error as? CaptureProcessingError {
            switch failure {
            case .invalidResponse, .incomplete, .inputTooLong: return "Task suggestions could not be prepared. The transcript and original audio are saved; check the text model or retry."
            default: return failure.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

extension TelegramStore {
    private func checkpoint(_ jobID: Int64, edit: (inout TelegramInboundJob) -> Void) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { throw CancellationError() }
        edit(&state.jobs[index]); try persist()
    }
    private func importMessage(_ initial: TelegramInboundJob, client: TelegramBotClient, botID: Int64, owner: Int64, generation current: UUID) async throws {
        guard let repository, let message = initial.update.message else { return }
        let rootID = TelegramCapture.identity(botID: botID, updateID: initial.id)
        var root = try await Task.detached { try repository.loadInbox().first { $0.id == rootID } }.value
        if root == nil || (root?.attachments.isEmpty == true && message.media != nil) {
            var attachment: LibraryPreparedAttachment?
            if let media = message.media {
                let downloaded: (Data, String)
                do { downloaded = try await client.download(media) }
                catch {
                    if !Task.isCancelled, current == generation {
                        let fallback = try await Task.detached { try TelegramCapture.save(initial.update, botID: botID, ownerID: owner, attachment: nil, repository: repository) }.value
                        inbox.accept(fallback); if !message.isAudio { inbox.enqueue(fallback); inbox.startJobs() }; inbox.library.scheduleBackup()
                    }
                    throw error
                }
                let (data, filePath) = downloaded
                let name = media.file_name ?? URL(fileURLWithPath: filePath).lastPathComponent
                let nameExt = URL(fileURLWithPath: name).pathExtension.lowercased()
                let rawExt = nameExt.isEmpty ? URL(fileURLWithPath: filePath).pathExtension.lowercased() : nameExt
                let ext = LibraryPolicy.attachmentExtensions.contains(rawExt) ? rawExt : "bin"
                attachment = try await Task.detached { try LibraryAttachments.prepare(data: data, name: name, extension: ext, localState: repository.localState) }.value
            }
            try Task.checkCancellation(); guard current == generation else { return }
            let prepared = attachment
            root = try await Task.detached { try TelegramCapture.save(initial.update, botID: botID, ownerID: owner, attachment: prepared, repository: repository) }.value
            if let root { inbox.accept(root); if !message.isAudio { inbox.enqueue(root); inbox.startJobs() } }
            inbox.library.scheduleBackup()
        }
        guard let root else { return }
        if !message.isAudio {
            state.queue(id: "reply:\(initial.id)", text: "Saved to Inbox · \(root.title)")
            return
        }
        state.queue(id: "accepted:\(initial.id)", text: "Audio saved to Inbox. Transcribing…")
        try persist(); try await flushOutbox(using: client, generation: current)
        var job = state.jobs.first { $0.id == initial.id } ?? initial
        let configuredModel = settings.audioModel.isEmpty ? defaultAudioModel() : settings.audioModel
        let audioKey = LibraryHash.digest(Data((ai.connection.baseURL + "|" + configuredModel).utf8))
        if job.audioConfiguration != audioKey {
            try checkpoint(job.id) { $0.audioConfiguration = audioKey; $0.chunkText = [:]; $0.transcript = nil; $0.drafts = nil }
            job.audioConfiguration = audioKey; job.chunkText = [:]; job.transcript = nil; job.drafts = nil
        }
        if job.transcript == nil {
            guard let source = root.attachments.first else { throw TelegramBotError.configuration("Audio attachment is missing. Retry this capture.") }
            let model = settings.audioModel.isEmpty ? defaultAudioModel() : settings.audioModel
            guard !model.isEmpty else { throw TelegramBotError.configuration("Set a transcription model in Telegram settings, then retry this audio capture.") }
            let file = try repository.validatedURL(source.path), folder = repository.localState.appendingPathComponent("telegram-audio/\(rootID)/chunks")
            let preparation = Task.detached(priority: .utility) { try TelegramAudio.prepare(source: file, directory: folder) }
            let parts = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            let connection = ai.connection, key = try await ai.apiKey()
            for part in parts where job.chunkText[part.id] == nil {
                try Task.checkCancellation(); guard current == generation else { return }
                try await inbox.library.consumeBudget()
                let result = try await MeetingProcessingClient().transcribe(file: part.file, partID: part.id, offset: part.offset, duration: part.duration, language: .automatic, speakerLabels: false, connection: connection, audioModel: model, apiKey: key)
                let text = result.segments.map(\.text).joined(separator: " ")
                try checkpoint(job.id) { $0.chunkText[part.id] = text }; job.chunkText[part.id] = text
            }
            let text = parts.compactMap { job.chunkText[$0.id] }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TelegramBotError.configuration("No speech was recognized. Original audio is in Inbox; try a different model and retry.") }
            let full = [message.caption ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            try checkpoint(job.id) { $0.transcript = full }; job.transcript = full
            let updated = try await Task.detached { try TelegramCapture.finishAudio(update: initial.update, botID: botID, transcript: full, drafts: [], repository: repository) }.value
            for item in updated { inbox.accept(item) }
            inbox.library.scheduleBackup()
        }
        guard let transcript = job.transcript else { return }
        if job.drafts == nil {
            var drafts: [TelegramDraft] = []
            if settings.splitAudio {
                let key = try await ai.apiKey(), connection = ai.connection
                var remainder = transcript[...]
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(5500, remainder.count)), text = String(remainder[..<end])
                    remainder = remainder[end...]
                    try await inbox.library.consumeBudget()
                    do {
                        let result = try await LiteLLMClient().process(text, knownTags: inbox.knownTags(), connection: connection, apiKey: key)
                        drafts += result.map(TelegramDraft.init)
                    } catch CaptureProcessingError.noTasks { }
                }
                var seen = Set<String>(); drafts = drafts.filter { seen.insert($0.title.lowercased()).inserted }
                if drafts.count > 12 { drafts = [] }
            }
            let retained = drafts
            try checkpoint(job.id) { $0.drafts = retained }; job.drafts = drafts
        }
        try Task.checkCancellation(); guard current == generation else { return }
        let selectedDrafts = job.drafts ?? []
        let results = try await Task.detached { try TelegramCapture.finishAudio(update: initial.update, botID: botID, transcript: transcript, drafts: selectedDrafts, repository: repository) }.value
        for item in results { inbox.accept(item); if item.active { inbox.enqueue(item) } }
        inbox.startJobs(); inbox.library.scheduleBackup()
        state.queue(id: "reply:\(job.id)", text: selectedDrafts.count > 1 ? "Transcribed · \(selectedDrafts.count) suggestions in Inbox. Original audio and transcript are kept in the Inbox archive." : "Transcribed · saved in Inbox.")
    }
    private func flushOutbox(using client: TelegramBotClient, generation current: UUID) async throws {
        guard !sending, let owner = state.ownerID else { return }
        sending = true; defer { sending = false }
        for outgoing in state.outbox where outgoing.attemptedAt == nil && outgoing.expiresAt > Date() && (outgoing.notBefore ?? .distantPast) <= Date() {
            guard current == generation, settings.enabled, !Task.isCancelled else { return }
            guard let index = state.outbox.firstIndex(where: { $0.id == outgoing.id }) else { continue }
            state.outbox[index].attemptedAt = Date(); try persist()
            do {
                try await client.send(chatID: owner, text: outgoing.text)
                guard current == generation else { return }
                state.outbox.removeAll { $0.id == outgoing.id }; state.delivered[outgoing.id] = Date(); try persist()
            } catch {
                if let index = state.outbox.firstIndex(where: { $0.id == outgoing.id }) {
                    if case TelegramBotError.http(429, _) = error {
                        state.outbox[index].attemptedAt = nil
                        state.outbox[index].notBefore = Date().addingTimeInterval(Double((error as? TelegramBotError)?.retryAfter ?? 60))
                        state.outbox[index].lastError = nil
                    } else { state.outbox[index].lastError = "Telegram delivery was not confirmed. Retrying may send a duplicate. " + safeError(error) }
                    try persist()
                }
                if Task.isCancelled { throw CancellationError() }
                // Never blindly replay an uncertain send: Bot API has no sendMessage idempotency key.
            }
        }
    }
    private func scheduleNotifications() async throws {
        guard state.ownerID != nil else { return }
        let date = Date(), timeZone = inbox.library.repository.flatMap { try? $0.settings() } ?? PlanningSettings()
        let calendar = PlannerDate.calendar(timeZone), minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if settings.dailyDigest, minute >= settings.digestMinute {
            state.queue(id: "digest:" + PlannerDate.key(date, settings: timeZone), text: digest(date), expiresAt: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!)
        }
        if settings.urgentAlerts {
            for task in urgent().filter({ $0.quadrant == .doFirst && $0.isEligible }) {
                state.queue(id: "urgent:" + task.id, text: "Q1 · \(task.title)\n/task \(task.id.prefix(8))")
            }
        }
        if settings.eventAlerts {
            if date >= nextReminders {
                cachedReminders = try await reminders(); nextReminders = date.addingTimeInterval(30)
            }
            for reminder in cachedReminders where reminder.fireDate <= date && reminder.start > date {
                let format = DateFormatter(); format.timeZone = calendar.timeZone; format.dateFormat = "HH:mm"
                state.queue(id: "event:\(reminder.id):\(Int(reminder.start.timeIntervalSince1970))", text: "In 1 minute · \(reminder.title)\n\(format.string(from: reminder.start))–\(format.string(from: reminder.end))", expiresAt: reminder.start)
            }
        }
        try persist()
    }
}
