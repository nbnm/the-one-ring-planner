import SwiftUI
import RingCore

struct LibrarySettingsSections: View {
    @ObservedObject var library: LibraryStore
    @State private var automation = LibraryAutomationSettings()
    @State private var remote = ""
    @State private var backupToken = ""
    @State private var backupAuthentication = BackupAuthentication.githubCLI
    @State private var scopeAccepted = false
    @State private var selectRestoreConfirmation = false
    init(library: LibraryStore) {
        self.library = library; _automation = State(initialValue: library.settings); _remote = State(initialValue: library.backup.remoteURL); _backupAuthentication = State(initialValue: library.backup.authentication ?? (library.backup.enabled ? .token : .githubCLI))
    }
    var body: some View {
        Section("Library") {
            DisclosureGroup("AI organization & search") {
                Toggle("Automatically organize saved Library notes", isOn: $automation.enabled)
                Text("When enabled, note text and locally extracted image text go to your saved LiteLLM gateway. Original text stays exact. Tasks and meetings keep their existing consent flows.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                TextField("Library text model (blank uses task model)", text: $automation.textModel)
                TextField("Vision model alias", text: $automation.visionModel)
                Toggle("Send Library image thumbnails for organization", isOn: $automation.allowImages)
                Text("Images stay local until you enable this option and verify the vision alias. Each verification sends two synthetic swatches.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Verify vision") { Task { await library.saveAutomation(automation); await library.verifyVision() } }.disabled(library.working || library.demo || automation.visionModel.isEmpty)
                    Text(library.capabilities.visionConfiguration == nil ? "Not verified" : "Verified for saved alias").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                }
                TextField("Embedding model alias", text: $automation.embeddingModel)
                HStack {
                    Button("Verify embeddings") { Task { await library.saveAutomation(automation); await library.verifyEmbedding() } }.disabled(library.working || library.demo || automation.embeddingModel.isEmpty)
                    Text(library.capabilities.embeddingConfiguration == nil ? "Keyword search only" : "Embedding response verified").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                }
                Stepper("Monthly request budget: \(automation.monthlyRequests)", value: $automation.monthlyRequests, in: 1...10000, step: 10)
                Text("The budget counts requests, including probes and retries; provider pricing is separate. Large notes are stored in full; AI analyzes bounded excerpts.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Button("Save Library automation") { Task { await library.saveAutomation(automation) } }
                DisclosureGroup("Background jobs") {
                    ForEach(library.jobs.filter { $0.lastError != nil }) { job in Text(job.lastError ?? "").font(Theme.body(11)).foregroundStyle(Theme.alert) }
                    Button("Retry jobs and rebuild search") { Task { await library.retryJobs() } }
                }
            }
        }
        Section("Data & backup") {
            LabeledContent("Local save", value: library.localStateDescription.isEmpty ? "Loading…" : library.localStateDescription)
            if let success = library.backupState.lastSuccess { LabeledContent("Last verified remote backup", value: success.formatted(date: .abbreviated, time: .shortened)) }
            else { LabeledContent("Remote backup", value: "Not yet verified") }
            if let sha = library.backupState.verifiedCommit { Text("Verified commit: \(sha)").font(Theme.body(10)).textSelection(.enabled) }
            if let error = library.backupState.lastError { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled) }
            DisclosureGroup("Private GitHub remote") {
                TextField("https://github.com/owner/private-data.git", text: $remote)
                Picker("GitHub login", selection: $backupAuthentication) {
                    Text("GitHub CLI · existing login").tag(BackupAuthentication.githubCLI)
                    Text("Saved token").tag(BackupAuthentication.token)
                }
                if backupAuthentication == .token { SecureField("GitHub token (stored in Keychain)", text: $backupToken) }
                else { Text("Uses your existing gh auth login on this Mac. No additional token is saved.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                Toggle("I understand this backs up all Data records and their Git history, including tasks, captures, plans and notes", isOn: $scopeAccepted)
                Text("Use a separate private repository. A path-limited push cannot hide old task history. Notes-only backup needs a separate export repository. The public app source repository is blocked.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Verify & enable backup") { let token = backupToken; backupToken = ""; Task { await library.configureBackup(remote: remote, token: token, scopeAccepted: scopeAccepted, authentication: backupAuthentication) } }.disabled(!scopeAccepted || remote.isEmpty || library.demo || library.backingUp)
                    Button(library.backingUp ? "Backing up…" : "Back up now") { Task { await library.backUpNow() } }.disabled(!library.backup.enabled || library.backingUp)
                    Button("Disable") { library.disableBackup() }.disabled(!library.backup.enabled)
                }
                Text("Ordinary Git only: 20 MB per attachment, 256 MB total attachment storage. LFS/filter pointers are rejected; no LFS backup is claimed. Private visibility is checked again before each upload. Conflicting remote changes pause backup; no automatic merge or force-push.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            }
            DisclosureGroup("Archive & restore") {
                Text("Archives contain current canonical records and actual attachment bytes. Data archives exclude Meetings; full-app archives add meeting files. Archives exclude credentials, signing keys, local settings and prior Git history. The private remote retains Git history.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Export Data archive…") { library.exportArchive(includeMeetings: false) }
                    Button("Export full-app archive…") { library.exportArchive(includeMeetings: true) }.disabled(library.recordingIsActive())
                }.disabled(library.working)
                HStack {
                    Button("Preview archive restore…") { library.previewArchive() }
                    Button("Preview remote restore") { Task { await library.previewRemote() } }.disabled(library.backup.remoteURL.isEmpty || library.demo)
                }.disabled(library.working)
                if let preview = library.restorePreview {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Validated preview: \(preview.noteCount) notes · \(preview.taskCount) tasks · \(preview.inboxCount) in Inbox · \(preview.includesMeetings ? "Meetings included" : "Data only")").font(Theme.body(12, weight: .semibold))
                        Text("The search index is rebuilt in a separate workspace. Switching requires a restart and leaves the current workspace intact. Calendar sync starts disabled for review.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                        HStack { Button("Use on next launch…") { selectRestoreConfirmation = true }.disabled(library.recordingIsActive() || library.saving || library.working); Button("Keep current workspace") { library.restorePreview = nil } }
                    }.padding(.vertical, 10)
                }
                Text("Trash and ordinary deletion do not erase earlier Git versions or existing backups.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            }
        }
        if let message = library.serviceMessage { Section { HStack { Text(message).font(Theme.body(11)).textSelection(.enabled); Spacer(); Button { library.serviceMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss Library settings message") } } }
        if let error = library.error { Section { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert).textSelection(.enabled) } }
    }
}
