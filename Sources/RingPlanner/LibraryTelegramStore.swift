import Foundation
import RingCore

extension LibraryStore {
    func configureTelegram(endpoint: String, token: String, enabled: Bool) async {
        guard !demo, let repo = repository else { return }
        do {
            if !token.isEmpty { try ai.saveSecret(token, account: "library-telegram-token") }
            let credential = try await ai.secret(account: "library-telegram-token")
            let client = try LibraryTelegramClient(endpoint: endpoint, token: credential)
            _ = try await client.pending()
            var value = LibraryTelegramSettings(); value.endpoint = endpoint; value.enabled = enabled
            try Self.write(value, file: repo.localState.appendingPathComponent("library-telegram.json")); telegram = value
            serviceMessage = "Hosted inbox connection verified. Captures import into Unreviewed, with durable retry protection."
            await pollTelegram()
        } catch { serviceMessage = error.localizedDescription }
    }
    func pollTelegram() async {
        guard !demo, telegram.enabled, importTask == nil, let repo = repository else { return }
        if let next = try? Self.read(Date.self, file: repo.localState.appendingPathComponent("library-telegram-next-attempt.json")), next > Date() { return }
        let endpoint = telegram.endpoint
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await ai.secret(account: "library-telegram-token")
                let client = try LibraryTelegramClient(endpoint: endpoint, token: credential)
                for capture in try await client.pending() {
                    guard telegram.enabled, telegram.endpoint == endpoint, !Task.isCancelled else { return }
                    let bytes = try await client.attachments(capture)
                    let note = try await Task.detached(priority: .utility) { try LibraryTelegramImporter.importCapture(capture, bytes: bytes, repository: repo) }.value
                    accept(note)
                    // HTTP acknowledgement is strictly after journal application and the local commit.
                    try await client.acknowledge(capture, noteID: note.id)
                    await enqueue(note); scheduleBackup()
                }
            } catch {
                serviceMessage = "Telegram import will retry; unacknowledged content stays in the hosted inbox. " + error.localizedDescription
                try? Self.write(Date().addingTimeInterval(120), file: repo.localState.appendingPathComponent("library-telegram-next-attempt.json"))
            }
        }
        await importTask?.value; importTask = nil
    }
}
