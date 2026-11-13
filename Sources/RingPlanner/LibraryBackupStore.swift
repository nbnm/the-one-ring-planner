import SwiftUI
import RingCore

extension LibraryStore {
    func configureBackup(remote: String, token: String, scopeAccepted: Bool, authentication: BackupAuthentication = .token) async {
        guard !demo, scopeAccepted else { serviceMessage = demo ? "Example mode never uploads a data repository." : "Confirm the full Data and Git history scope before configuring backup."; return }
        do {
            _ = try LibraryRemoteBackup.githubRepository(remote)
            if authentication == .token, !token.isEmpty { try ai.saveSecret(token, account: "library-backup-token") }
            let credential = try await backupCredential(authentication)

            try await LibraryRemoteBackup.verifyPrivate(remote, token: credential)
            var config = LibraryBackupSettings(); config.remoteURL = remote; config.verifiedPrivateRemote = remote; config.enabled = true; config.authentication = authentication
            guard let repo = repository else { return }
            try Self.write(config, file: repo.localState.appendingPathComponent("library-backup.json")); backup = config
            backupState = LibraryBackupState(); serviceMessage = "Private remote verified. Back up now or let the next local save trigger backup."
            await backUpNow()
        } catch { serviceMessage = error.localizedDescription }
    }
    func backupCredential(_ authentication: BackupAuthentication) async throws -> String {
        switch authentication {
        case .githubCLI: return try await Task.detached(priority: .utility) { try GitHubCLILogin.token() }.value
        case .token: return try await ai.secret(account: "library-backup-token")
        }
    }
    func disableBackup() {
        backupTask?.cancel(); backup.enabled = false
        if let repo = repository { try? Self.write(backup, file: repo.localState.appendingPathComponent("library-backup.json")) }
    }
    func scheduleBackup() {
        guard !demo, backup.enabled, !backingUp, (backupState.nextAttempt ?? .distantPast) <= Date() else { return }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !Task.isCancelled, let repo = self.repository else { return }
            let commit = try? await Task.detached { try repo.gitRead(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }.value
            if commit != self.backupState.verifiedCommit { await self.backUpNow() }
        }
    }
    func backUpNow() async {
        guard !demo, backup.enabled, !backingUp, let repo = repository else { return }
        backingUp = true; defer { backingUp = false }
        let config = backup
        do {
            let token = try await backupCredential(config.authentication ?? .token)
            // Recheck visibility before every upload; an old verification is insufficient.
            try await LibraryRemoteBackup.verifyPrivate(config.remoteURL, token: token)
            backupState.localCommit = try await Task.detached { try repo.gitRead(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }.value
            let commit = try await Task.detached(priority: .utility) { try LibraryRemoteBackup.push(repo, settings: config, token: token) }.value
            guard backup.remoteURL == config.remoteURL else { return }
            backupState.verifiedCommit = commit; backupState.lastSuccess = Date(); backupState.lastError = nil; backupState.nextAttempt = nil
        } catch {
            backupState.lastError = error.localizedDescription
            let conflict = error.localizedDescription.contains("another version") || error.localizedDescription.contains("not a writable private")
            let permanentHTTP = (error as? LibraryHTTPFailure).map { !$0.transient } ?? false
            let invalidPolicy: Bool = { if case LibraryError.invalid = error { return true }; return false }()
            backupState.nextAttempt = conflict || permanentHTTP || invalidPolicy ? .distantFuture : Date().addingTimeInterval(120)
        }
        try? Self.write(backupState, file: repo.localState.appendingPathComponent("library-backup-state.json"))
    }
    func exportArchive(includeMeetings: Bool) {
        guard let repo = repository else { return }
        guard !includeMeetings || !recordingIsActive() else { error = "Finish recording or processing before creating a full-app archive."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Create archive here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let source = includeMeetings ? meetingsRoot : nil
        let destination = folder.appendingPathComponent("OneRing-\(includeMeetings ? "FullApp" : "Data")-\(UUID().uuidString.prefix(8)).ringbackup")
        working = true
        Task { defer { working = false }; do {
            try await Task.detached(priority: .utility) { try LibraryArchive.create(repository: repo, meetings: source, destination: destination) }.value
            serviceMessage = "Archive created with actual attachment bytes. \(includeMeetings ? "Meeting files are included." : "Meetings are not included.") Credentials and local settings are excluded."
        } catch { self.error = error.localizedDescription } }
    }
    func previewArchive() {
        guard let repo = repository, !working else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Preview archive"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let target = repo.localState.appendingPathComponent("library-restores/\(UUID().uuidString)")
        working = true
        Task { defer { working = false }; do { restorePreview = try await Task.detached(priority: .utility) { try LibraryArchive.restoreArchive(source, into: target) }.value } catch { self.error = error.localizedDescription } }
    }
    func previewRemote() async {
        guard !demo, let repo = repository, !working else { return }
        working = true; defer { working = false }
        do {
            let remote = backup.remoteURL, token = try await backupCredential(backup.authentication ?? .token)
            try await LibraryRemoteBackup.verifyPrivate(remote, token: token)
            let target = repo.localState.appendingPathComponent("library-restores/\(UUID().uuidString)")
            restorePreview = try await Task.detached(priority: .utility) { try LibraryArchive.restoreRemote(remote, token: token, into: target) }.value
        } catch { self.error = error.localizedDescription }
    }
    func selectRestore() async {
        guard let preview = restorePreview, !recordingIsActive(), !saving, !working else { error = "Finish recording, processing and pending saves before switching workspaces."; return }
        working = true; defer { working = false }
        do {
            // Selection never overwrites the active workspace. Demo selections are isolated too.
            let parent = demo ? repository!.localState.appendingPathComponent("demo-selected-restores") : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("The One Ring Planner/Restored")
            let target = parent.appendingPathComponent(UUID().uuidString.lowercased())
            try await Task.detached {
                _ = try LibraryArchive.validateWorkspace(preview.workspace, includesMeetings: preview.includesMeetings)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for name in ["Data", "Local"] + (preview.includesMeetings ? ["Meetings"] : []) {
                    try FileManager.default.copyItem(at: preview.workspace.appendingPathComponent(name), to: target.appendingPathComponent(name))
                }
            }.value
            restoreSelection?(target, preview.includesMeetings); restorePreview = nil
            serviceMessage = "A validated workspace is selected for the next launch. Quit and reopen to switch; the current workspace remains available. Calendar sync starts disabled for review."
        } catch { self.error = error.localizedDescription }
    }
}
