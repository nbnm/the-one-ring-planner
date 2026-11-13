import SwiftUI
import RingCore

@MainActor final class SharedInboxStore: ObservableObject {
    let repository: DataRepository?
    let library: LibraryStore
    let demo: Bool
    @Published var items: [InboxItem] = []
    @Published var jobs: [InboxJob] = []
    @Published var error: String?
    @Published var saving = false
    @Published var selected: InboxItem?
    private var generation: Task<Void, Never>?
    private var timer: Timer?
    var knownTags: () -> [String] = { [] }
    var active: [InboxItem] { items.filter(\.active) }
    init(repository: DataRepository?, library: LibraryStore, demo: Bool) {
        self.repository = repository; self.library = library; self.demo = demo
        Task {
            await reload()
            if demo && active.isEmpty { await seedDemo() }
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.startJobs() } }
            startJobs()
        }
    }
    func reload() async {
        guard let repository else { return }
        do {
            let loaded = try await Task.detached { try repository.loadInbox() }.value
            items = loaded
            jobs = (try? LibraryStore.read([InboxJob].self, file: repository.localState.appendingPathComponent("inbox-jobs.json"))) ?? []
            for item in loaded where item.active && item.classification == nil { enqueue(item) }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func capture(id: String, createdAt: Date, text: String, files: [URL]) async -> Bool {
        guard !saving, let repository, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return false }
        saving = true; error = nil; defer { saving = false }
        do {
            let item = try await Task.detached(priority: .userInitiated) {
                var seen = Set<String>()
                let prepared = try LibraryMedia.prepare(files, repository: repository).filter { seen.insert($0.attachment.hash).inserted }
                let item = InboxItem(id: id, text: text, attachments: prepared.map(\.attachment), now: createdAt)
                return try repository.saveInbox(item, expectedRevision: nil, attachments: prepared.map(\.write))
            }.value
            accept(item); enqueue(item); library.scheduleBackup(); startJobs(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func accept(_ item: InboxItem) {
        items.removeAll { $0.id == item.id }; items.append(item); items.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        if selected?.id == item.id { selected = item.active ? item : nil }
    }
    @discardableResult func saveEdit(_ item: InboxItem, expectedRevision: Int) async -> Bool {
        guard let repository else { return false }
        do {
            let saved = try await Task.detached { try repository.saveInbox(item, expectedRevision: expectedRevision) }.value
            accept(saved); jobs.removeAll { $0.itemID == saved.id }; if saved.active && saved.classification == nil { enqueue(saved) }; await persistJobs(); library.scheduleBackup(); startJobs(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func archive(_ item: InboxItem) {
        var value = item; value.revision += 1; value.archived = true
        Task { _ = await saveEdit(value, expectedRevision: item.revision) }
    }
    func restore(_ item: InboxItem) {
        var value = item; value.revision += 1; value.archived = false
        Task { _ = await saveEdit(value, expectedRevision: item.revision) }
    }
    func retry(_ item: InboxItem) {
        jobs.removeAll { $0.itemID == item.id }; enqueue(item)
        Task { await persistJobs(); startJobs() }
    }
    func enqueue(_ item: InboxItem) {
        guard !item.awaitingTranscription else { return }
        if !jobs.contains(where: { $0.itemID == item.id && $0.revision == item.revision }) { jobs.append(InboxJob(item)) }
    }
    func startJobs() {
        guard generation == nil else { return }
        generation = Task { [weak self] in await self?.runJobs(); self?.generation = nil }
    }
    private func runJobs() async {
        guard let repository else { return }
        while !Task.isCancelled {
            jobs.removeAll { job in !items.contains(where: { $0.id == job.itemID && $0.revision == job.revision && $0.active }) }
            guard let job = jobs.first(where: { ($0.nextAttempt ?? .distantPast) <= Date() }), let item = items.first(where: { $0.id == job.itemID }) else { break }
            do {
                let classification: InboxClassification
                if demo {
                    // Isolated fixtures only; production always calls the saved LLM.
                    let reference = !ReferenceLinks.extract(item.text).isEmpty || item.text.localizedCaseInsensitiveContains("palette") || item.text.localizedCaseInsensitiveContains("reference")
                    classification = InboxClassification(kind: reference ? .note : .task, title: String(item.title.prefix(120)), tags: ["Fellowship", "Work"])
                } else {
                    let connection = library.ai.connection
                    _ = try connection.endpoint()
                    let extracted = await Task.detached { item.attachments.map { (try? LibraryMedia.recognize($0, repository: repository)) ?? "" }.joined(separator: "\n") }.value
                    let key = try await library.ai.apiKey()
                    try await library.consumeBudget()
                    classification = try await LibraryAIClient().classifyInbox(item, extractedText: extracted, knownTags: Array(Set(items.flatMap(\.tags) + library.allTags + knownTags())).sorted(), connection: connection, key: key)
                    guard library.ai.connection == connection else { throw LibraryError.stale }
                }
                guard let current = items.first(where: { $0.id == item.id }), current.revision == item.revision, current.active else { throw LibraryError.stale }
                var value = current; value.classification = classification; value.revision += 1
                let saved = try await Task.detached { try repository.saveInbox(value, expectedRevision: item.revision) }.value
                accept(saved); jobs.removeAll { $0.id == job.id }; library.scheduleBackup()
            } catch LibraryError.stale {
                jobs.removeAll { $0.id == job.id }
                if let current = items.first(where: { $0.id == item.id && $0.active && $0.classification == nil }) { enqueue(current) }
            } catch {
                if Task.isCancelled { break }
                if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[index].attempts += 1; jobs[index].lastError = error.localizedDescription
                    let retryable = error is URLError || (error as? LibraryHTTPFailure)?.transient == true
                    jobs[index].nextAttempt = retryable && jobs[index].attempts < 4 ? Date().addingTimeInterval(min(300, pow(2, Double(jobs[index].attempts)) * 15)) : .distantFuture
                }
            }
            await persistJobs()
        }
        await persistJobs()
    }
    private func persistJobs() async {
        guard let repository else { return }; let snapshot = jobs
        do { try await Task.detached { try LibraryStore.write(snapshot, file: repository.localState.appendingPathComponent("inbox-jobs.json")) }.value }
        catch { self.error = "Inbox retry state could not be saved. Captured items remain local." }
    }
    func shutdown() async { timer?.invalidate(); generation?.cancel(); await generation?.value; await persistJobs() }
    private func seedDemo() async {
        guard let repository else { return }
        do {
            let fixtures = [InboxItem(text: "Ask Sam to check the garden gate"), InboxItem(text: "Reference: moss, warm stone and old gold for Bag End"), InboxItem(text: "A useful map for the journey\nhttps://example.com/fellowship-map")]
            for item in fixtures { let saved = try await Task.detached { try repository.saveInbox(item, expectedRevision: nil) }.value; accept(saved); enqueue(saved) }
        } catch { self.error = error.localizedDescription }
    }
}
