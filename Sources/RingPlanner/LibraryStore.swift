import SwiftUI
import Combine
import RingCore

@MainActor final class LibraryStore: ObservableObject {
    let repository: DataRepository?
    let ai: CaptureAISettings
    let demo: Bool
    @Published var notes: [LibraryNote] = []
    @Published var results: [LibraryNote] = []
    @Published var query = "" { didSet { updateSearch() } }
    @Published var collection = LibraryCollection.all { didSet { updateSearch() } }
    @Published var tag = "" { didSet { updateSearch() } }
    @Published var kind: LibraryKind? { didSet { updateSearch() } }
    @Published var showingArchived = false { didSet { updateSearch() } }
    @Published var showingTrash = false { didSet { updateSearch() } }
    @Published var folders: [String] = []
    @Published var folder: String? { didSet { updateSearch() } }
    @Published var gallery = true
    @Published var selectedID: String?
    @Published var error: String?
    @Published var saving = false
    @Published var preparingAttachments = 0
    @Published var loading = true
    @Published var draft = LibraryDraft() { didSet { retainDraft() } }
    @Published var derived: [String: LibraryDerivedEntry] = [:]
    @Published var localStateDescription = ""
    @Published var jobs: [LibraryJob] = []
    @Published var settings = LibraryAutomationSettings()
    @Published var capabilities = LibraryCapabilities()
    @Published var serviceMessage: String?
    @Published var working = false
    @Published var semantic = false
    var meetingsRoot: URL?
    @Published var backingUp = false
    @Published var backup = LibraryBackupSettings()
    @Published var backupState = LibraryBackupState()
    @Published var telegram = LibraryTelegramSettings()
    @Published var restorePreview: LibraryRestorePreview?
    var recordingIsActive: () -> Bool = { false }
    var restoreSelection: ((URL, Bool) -> Void)?
    private var searchTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    var jobTask: Task<Void, Never>?
    var backupTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var serviceTimer: Timer?
    var lastSaveAt: Date?
    init(repository: DataRepository?, ai: CaptureAISettings, demo: Bool) {
        self.repository = repository; self.ai = ai; self.demo = demo
        if let repository {
            draft = (try? Self.read(LibraryDraft.self, file: repository.localState.appendingPathComponent("library-draft.json"))) ?? LibraryDraft()
            settings = (try? Self.read(LibraryAutomationSettings.self, file: repository.localState.appendingPathComponent("library-automation.json"))) ?? LibraryAutomationSettings()
            // This update explicitly enables automatic categorization once; later user choices remain respected.
            let taggingPreference = repository.localState.appendingPathComponent("capture-tagging-enabled-v1.json")
            if !FileManager.default.fileExists(atPath: taggingPreference.path) {
                settings.enabled = true
                try? Self.write(settings, file: repository.localState.appendingPathComponent("library-automation.json"))
                try? Self.write(true, file: taggingPreference)
            }
            capabilities = (try? Self.read(LibraryCapabilities.self, file: repository.localState.appendingPathComponent("library-capabilities.json"))) ?? LibraryCapabilities()
            backup = (try? Self.read(LibraryBackupSettings.self, file: repository.localState.appendingPathComponent("library-backup.json"))) ?? LibraryBackupSettings()
            backupState = (try? Self.read(LibraryBackupState.self, file: repository.localState.appendingPathComponent("library-backup-state.json"))) ?? LibraryBackupState()
            telegram = (try? Self.read(LibraryTelegramSettings.self, file: repository.localState.appendingPathComponent("library-telegram.json"))) ?? LibraryTelegramSettings()
        }
        Task { await reload(); if demo && (CommandLine.arguments.contains("--library-demo") || Bundle.main.object(forInfoDictionaryKey: "OneRingIsolatedDemo") as? Bool == true) { await seedLibraryDemo() }; await resumeServices() }
    }
    var selected: LibraryNote? { notes.first { $0.id == selectedID } }
    var allTags: [String] { Array(Set(notes.flatMap(\.displayTags))).sorted() }
    func reload() async {
        guard let repo = repository else { loading = false; error = "Local storage is unavailable. Your capture draft is retained."; return }
        do {
            let (loaded,index,jobs) = try await Task.detached(priority: .utility) {
                (try repo.loadLibrary(), (try? Self.read([String: LibraryDerivedEntry].self, file: repo.localState.appendingPathComponent("library-index.json"))) ?? [:], (try? Self.read([LibraryJob].self, file: repo.localState.appendingPathComponent("library-jobs.json"))) ?? [])
            }.value
            notes = loaded.notes; folders = try repo.libraryFolders(); derived = index; self.jobs = jobs
            for note in notes where note.trashedAt == nil && !self.jobs.contains(where: { $0.noteID == note.id && $0.revision == note.revision }) { self.jobs.append(LibraryJob(noteID: note.id, revision: note.revision)) }
            if !loaded.failures.isEmpty { error = "\(loaded.failures.count) damaged note file(s) were preserved. Other notes are available. Restore missing notes from Data & backup." }
            localStateDescription = "Saved and committed on this Mac"; loading = false; updateSearch()
        } catch { self.error = error.localizedDescription; loading = false }
    }
    func updateSearch() {
        searchTask?.cancel()
        let notes = notes.filter { LibraryFolders.contains(folder, note: $0) }, query = query, collection = collection, tag = tag, kind = kind, derived = derived, archived = showingArchived, trash = showingTrash
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120)); guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { LibrarySearch.matches(notes, query: query, collection: collection, tag: tag, kind: kind, derived: derived, archived: archived, trash: trash) }.value
            guard !Task.isCancelled else { return }; results = matches
        }
    }
    @discardableResult func saveDraft() async -> Bool {
        guard !saving, preparingAttachments == 0, draft.hasContent, let repo = repository else { return false }
        let captured = draft; let targetFolder = folder; saving = true; error = nil; defer { saving = false }
        do {
            let note = try await Task.detached(priority: .userInitiated) {
                let prepared = try LibraryMedia.prepare(captured.files, repository: repo)
                var body = captured.body
                if body.isEmpty {
                    body = try captured.files.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
                }
                var seen = Set<String>()
                let unique = prepared.filter { seen.insert($0.attachment.hash).inserted }
                var note = LibraryNote(id: captured.id, title: captured.title, body: body, prompt: captured.prompt, comments: captured.comments, sourceURL: captured.sourceURL.isEmpty ? ReferenceLinks.extract(body).first?.absoluteString ?? "" : captured.sourceURL, attachments: unique.map(\.attachment), originals: [LibraryOriginal(id: captured.id, text: body, prompt: captured.prompt, comments: captured.comments, sourceURL: captured.sourceURL, attachmentHashes: unique.map { $0.attachment.hash }, capturedAt: captured.createdAt)], now: captured.createdAt)
                note.folder = targetFolder.flatMap { $0.isEmpty ? nil : $0 }
                return try repo.saveLibrary(note, expectedRevision: nil, attachments: unique.map(\.write))
            }.value
            accept(note); if draft == captured { draft = LibraryDraft() }; await enqueue(note); scheduleBackup(); return true
        } catch {
            self.error = error.localizedDescription
            localStateDescription = "Save needs attention · draft retained"
            // Files may already be durable while the journal waits for a local commit.
            if let loaded = try? await Task.detached(operation: { try repo.loadLibrary() }).value { notes = loaded.notes; updateSearch() }
            return false
        }
    }
    @discardableResult func saveEdit(_ draft: LibraryNote, expectedRevision: Int, files: [URL] = []) async -> Bool {
        guard !saving, let repo = repository else { return false }
        saving = true; error = nil; defer { saving = false }
        do {
            let saved = try await Task.detached {
                let prepared = try LibraryMedia.prepare(files, repository: repo)
                var value = draft
                for a in prepared where !value.attachments.contains(where: { $0.hash == a.attachment.hash }) { value.attachments.append(a.attachment) }
                if !prepared.isEmpty { value.originals.append(LibraryOriginal(text: "", attachmentHashes: prepared.map { $0.attachment.hash }, channel: "edit")) }
                return try repo.saveLibrary(value, expectedRevision: expectedRevision, attachments: prepared.map(\.write))
            }.value
            accept(saved); await enqueue(saved); scheduleBackup(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func mutate(_ note: LibraryNote, _ edit: (inout LibraryNote) -> Void) {
        var value = note; edit(&value); value.revision += 1; value.updatedAt = Date()
        Task { _ = await saveEdit(value, expectedRevision: note.revision) }
    }
    func accept(_ note: LibraryNote) {
        notes.removeAll { $0.id == note.id }; notes.insert(note, at: 0); lastSaveAt = Date()
        folders = (try? LibraryFolders.expanded(folders + notes.compactMap(\.folder))) ?? folders
        localStateDescription = "Saved and committed on this Mac"; updateSearch()
    }
    func addFiles(_ files: [URL]) {
        guard !files.isEmpty, let repo = repository else { return }
        preparingAttachments += 1
        Task {
            defer { preparingAttachments -= 1 }
            do {
                let copies = try await Task.detached(priority: .userInitiated) {
                    try files.map { file -> URL in
                        let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size <= LibraryPolicy.maximumAttachmentBytes else { throw LibraryError.invalid("Attachments must be at most 20 MB.") }
                        let folder = repo.localState.appendingPathComponent("library-drafts/\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let destination = folder.appendingPathComponent(file.lastPathComponent)
                        try FileManager.default.copyItem(at: file, to: destination); return destination
                    }
                }.value
                draft.files.append(contentsOf: copies)
            } catch { self.error = error.localizedDescription }
        }
    }
    func pasteImage(_ data: Data) {
        guard let repo = repository else { return }
        preparingAttachments += 1
        Task { defer { preparingAttachments -= 1 }; do { let file = try await Task.detached { try LibraryMedia.clipboardImage(data, localState: repo.localState) }.value; draft.files.append(file) } catch { self.error = error.localizedDescription } }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = LibraryMedia.supported; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func export(_ note: LibraryNote) {
        guard let repo = repository else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { do { try await Task.detached { try LibraryPortable.export(note, repository: repo, to: folder.appendingPathComponent("Note-\(note.id)")) }.value } catch { self.error = error.localizedDescription } }
    }
    func prepareShutdown() async {
        serviceTimer?.invalidate(); backupTask?.cancel(); importTask?.cancel(); jobTask?.cancel(); draftTask?.cancel()
        await jobTask?.value; await importTask?.value
        while saving || preparingAttachments > 0 { try? await Task.sleep(for: .milliseconds(50)) }
        if let repo = repository { let value = draft; try? await Task.detached { try Self.write(value, file: repo.localState.appendingPathComponent("library-draft.json")) }.value }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func retainDraft() {
        draftTask?.cancel(); guard let repo = repository else { return }; let value = draft
        draftTask = Task { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
            do { try await Task.detached { try Self.write(value, file: repo.localState.appendingPathComponent("library-draft.json")) }.value } catch { self.error = "The capture draft could not be retained. Keep this window open and retry saving." }
        }
    }
    nonisolated static func read<T: Decodable>(_ type: T.Type, file: URL) throws -> T { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(type, from: Data(contentsOf: file)) }
    nonisolated static func write<T: Encodable>(_ value: T, file: URL) throws { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; try e.encode(value).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
}
