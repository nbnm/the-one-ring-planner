import SwiftUI
import RingCore
import ImageIO
import UniformTypeIdentifiers

extension LibraryStore {
    func resumeServices() async {
        startJobs()
        if !demo {
            serviceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startJobs(); self?.scheduleBackup() }
            }
            scheduleBackup()
        }
    }
    func enqueue(_ note: LibraryNote) async {
        jobs.removeAll { $0.noteID == note.id && $0.revision != note.revision }
        if note.trashedAt != nil { jobs.removeAll { $0.noteID == note.id } }
        else if !jobs.contains(where: { $0.noteID == note.id && $0.revision == note.revision }) { jobs.append(LibraryJob(noteID: note.id, revision: note.revision)) }
        await saveJobs(); startJobs()
    }
    func retryJobs() async {
        for index in jobs.indices { jobs[index].attempts = 0; jobs[index].nextAttempt = nil; jobs[index].lastError = nil; if derived[jobs[index].noteID]?.embeddingConfiguration != capabilities.embeddingConfiguration { jobs[index].embeddingDone = false } }
        for note in notes where note.trashedAt == nil { if !jobs.contains(where: { $0.noteID == note.id && $0.revision == note.revision }) { jobs.append(LibraryJob(noteID: note.id, revision: note.revision)) } }
        await saveJobs(); startJobs()
    }
    private var canEmbed: Bool {
        settings.enabled && !settings.embeddingModel.isEmpty && capabilities.embeddingConfiguration == LibraryCapabilities.key(baseURL: ai.connection.baseURL, model: settings.embeddingModel)
    }
    private var canUseImages: Bool {
        settings.allowImages && capabilities.visionConfiguration == LibraryCapabilities.key(baseURL: ai.connection.baseURL, model: settings.visionModel)
    }
    func startJobs() {
        guard jobTask == nil, repository != nil else { return }
        jobTask = Task { [weak self] in await self?.runJobs(); self?.jobTask = nil }
    }
    private func runJobs() async {
        guard let repo = repository else { return }
        while !Task.isCancelled {
            jobs.removeAll { job in !notes.contains { $0.id == job.noteID && $0.revision == job.revision && $0.trashedAt == nil } }
            guard let index = jobs.firstIndex(where: { job in
                guard (job.nextAttempt ?? .distantPast) <= Date(), let note = notes.first(where: { $0.id == job.noteID }) else { return false }
                return !job.ocrDone || (settings.enabled && !demo && note.automationAllowed && (!job.organizationDone || (canEmbed && !job.embeddingDone)))
            }) else { return }
            var job = jobs[index]
            guard let note = notes.first(where: { $0.id == job.noteID }) else { continue }
            do {
                if !job.ocrDone {
                    let extracted = await Task.detached(priority: .utility) {
                        note.attachments.map { attachment -> String in
                            _ = try? LibraryMedia.thumbnail(attachment, repository: repo)
                            return (try? LibraryMedia.recognize(attachment, repository: repo)) ?? ""
                        }.joined(separator: "\n")
                    }.value
                    guard notes.contains(where: { $0.id == note.id && $0.revision == note.revision }) else { throw LibraryError.stale }
                    derived[note.id] = LibraryDerivedEntry(revision: note.revision, extractedText: extracted); job.ocrDone = true
                    await saveIndex(); updateSearch()
                }
                if settings.enabled && note.automationAllowed && !demo {
                    let configuration = settings, connection = ai.connection
                    let baseURL = connection.baseURL
                    let key = try await ai.apiKey()
                    if !job.organizationDone {
                        let images = try await requestImages(note)
                        let alias = images.isEmpty ? (configuration.textModel.isEmpty ? connection.model : configuration.textModel) : configuration.visionModel
                        try await consumeBudget()
                        let result = try await LibraryAIClient().organize(note, extractedText: derived[note.id]?.extractedText ?? "", related: notes, images: images, connection: LiteLLMConnection(baseURL: baseURL, model: alias), key: key)
                        guard settings == configuration, ai.connection == connection, settings.enabled, let current = notes.first(where: { $0.id == note.id }), current.revision == note.revision else { throw LibraryError.stale }
                        let updated = try current.applying(result)
                        _ = try await Task.detached { try repo.saveLibrary(updated, expectedRevision: current.revision, message: "Organize Library reference") }.value
                        accept(updated); job.organizationDone = true; scheduleBackup()
                    }
                    if canEmbed && !job.embeddingDone {
                        try await consumeBudget()
                        let currentNote = notes.first { $0.id == note.id } ?? note
                        let embeddingText = [currentNote.displayTitle, currentNote.body, currentNote.prompt, currentNote.enrichment?.summary ?? "", currentNote.enrichment?.imageDescriptions.values.joined(separator: "\n") ?? "", derived[note.id]?.extractedText ?? ""].joined(separator: "\n")
                        let vector = try await LibraryAIClient().embedding(embeddingText, connection: LiteLLMConnection(baseURL: baseURL, model: configuration.embeddingModel), key: key, expectedDimensions: capabilities.embeddingDimensions)
                        guard settings == configuration, ai.connection == connection, notes.contains(where: { $0.id == note.id && $0.revision == note.revision }) else { throw LibraryError.stale }
                        var entry = derived[note.id] ?? LibraryDerivedEntry(revision: note.revision)
                        entry.embedding = vector; entry.embeddingConfiguration = capabilities.embeddingConfiguration; derived[note.id] = entry
                        job.embeddingDone = true; await saveIndex()
                    }
                }
                if let current = jobs.firstIndex(where: { $0.id == job.id }) { jobs[current] = job }
            } catch LibraryError.stale {
                jobs.removeAll { $0.id == job.id }
                if let current = notes.first(where: { $0.id == job.noteID && $0.trashedAt == nil }), !jobs.contains(where: { $0.noteID == current.id && $0.revision == current.revision }) {
                    jobs.append(LibraryJob(noteID: current.id, revision: current.revision))
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    job.nextAttempt = nil; job.lastError = nil
                    if let current = jobs.firstIndex(where: { $0.id == job.id }) { jobs[current] = job }
                    await saveJobs(); return
                }
                job.attempts += 1; job.lastError = error.localizedDescription
                let retryable = (error as? LibraryHTTPFailure)?.transient == true || error is URLError
                job.nextAttempt = retryable && job.attempts < 4 ? Date().addingTimeInterval((error as? LibraryHTTPFailure)?.retryAfter ?? min(300, pow(2, Double(job.attempts)) * 15)) : .distantFuture
                if let current = jobs.firstIndex(where: { $0.id == job.id }) { jobs[current] = job }
                serviceMessage = error.localizedDescription
            }
            await saveJobs()
        }
    }
    private func requestImages(_ note: LibraryNote) async throws -> [LibraryAIImage] {
        guard canUseImages, let repo = repository else { return [] }
        return try await Task.detached(priority: .utility) {
            try note.attachments.filter(\.isImage).prefix(4).compactMap { attachment in
                guard let file = try LibraryMedia.thumbnail(attachment, repository: repo) else { return nil }
                return LibraryAIImage(id: attachment.hash, bytes: try Data(contentsOf: file))
            }
        }.value
    }
    func consumeBudget() async throws {
        guard let repo = repository else { throw LibraryError.invalid("Library storage is unavailable.") }
        var ledger = (try? Self.read(LibraryRequestLedger.self, file: repo.localState.appendingPathComponent("library-budget.json"))) ?? LibraryRequestLedger()
        try ledger.consume(limit: settings.monthlyRequests)
        try Self.write(ledger, file: repo.localState.appendingPathComponent("library-budget.json"))
    }
    func saveAutomation(_ value: LibraryAutomationSettings) async {
        guard let repo = repository, value.monthlyRequests >= 1, value.monthlyRequests <= 10000 else { error = "Choose a monthly request budget between 1 and 10,000."; return }
        do {
            try Self.write(value, file: repo.localState.appendingPathComponent("library-automation.json"))
            if settings != value { for index in jobs.indices { jobs[index].organizationDone = false; jobs[index].embeddingDone = false } }
            settings = value
            await retryJobs(); serviceMessage = demo ? "Example mode keeps AI requests disabled." : "Library preferences saved. Local capture always works without AI."
        } catch { self.error = error.localizedDescription }
    }
    func verifyEmbedding() async {
        guard !demo, !working, let repo = repository else { serviceMessage = "Example mode does not contact the gateway."; return }
        working = true; defer { working = false }
        do {
            let base = ai.connection.baseURL, model = settings.embeddingModel
            try await consumeBudget(); let key = try await ai.apiKey()
            let result = try await LibraryAIClient().embedding("A synthetic Library capability check.", connection: LiteLLMConnection(baseURL: base, model: model), key: key)
            guard base == ai.connection.baseURL, model == settings.embeddingModel else { throw LibraryError.stale }
            capabilities.embeddingConfiguration = LibraryCapabilities.key(baseURL: base, model: model); capabilities.embeddingDimensions = result.count
            try Self.write(capabilities, file: repo.localState.appendingPathComponent("library-capabilities.json")); serviceMessage = "Embedding response verified (\(result.count) dimensions). Search by meaning is available."; await retryJobs()
        } catch { serviceMessage = error.localizedDescription }
    }
    func verifyVision() async {
        guard !demo, !working, let repo = repository else { serviceMessage = "Example mode does not contact the gateway."; return }
        working = true; defer { working = false }
        do {
            let base = ai.connection.baseURL, model = settings.visionModel
            let images = try await Task.detached {
                try [(UInt8(255),UInt8(0),UInt8(0)), (UInt8(0),UInt8(0),UInt8(255))].enumerated().map { index,color in
                    LibraryAIImage(id: "swatch-\(index)", bytes: try LibraryMedia.png(width: 8, height: 8) { _,_ in color }, mimeType: "image/png")
                }
            }.value
            try await consumeBudget(); try await consumeBudget(); let key = try await ai.apiKey()
            try await LibraryAIClient().verifyVision(images: images, connection: LiteLLMConnection(baseURL: base, model: model), key: key)
            guard base == ai.connection.baseURL, model == settings.visionModel else { throw LibraryError.stale }
            capabilities.visionConfiguration = LibraryCapabilities.key(baseURL: base, model: model)
            try Self.write(capabilities, file: repo.localState.appendingPathComponent("library-capabilities.json")); serviceMessage = "Vision verified with two synthetic swatches. Enable image organization to send Library thumbnails."; await retryJobs()
        } catch { serviceMessage = error.localizedDescription }
    }
    func searchSemantically() {
        guard !demo, canEmbed, !query.isEmpty, !working else { serviceMessage = "Verify an embedding alias in Library settings first. Keyword search is available offline."; return }
        let text = query, configuration = capabilities.embeddingConfiguration!, model = settings.embeddingModel, base = ai.connection.baseURL
        working = true
        Task {
            defer { working = false }
            do {
                try await consumeBudget(); let key = try await ai.apiKey()
                let vector = try await LibraryAIClient().embedding(text, connection: LiteLLMConnection(baseURL: base, model: model), key: key, expectedDimensions: capabilities.embeddingDimensions)
                guard query == text, capabilities.embeddingConfiguration == configuration, ai.connection.baseURL == base else { return }
                let candidates = LibrarySearch.matches(notes.filter { LibraryFolders.contains(folder, note: $0) }, query: "", collection: collection, tag: tag, kind: kind, archived: showingArchived, trash: showingTrash)
                let ranked = LibrarySearch.semantic(candidates, vector: vector, configuration: configuration, derived: derived)
                if ranked.isEmpty { error = "No matching indexed notes yet. Keyword results are still shown; let background indexing finish." } else { results = ranked }
            } catch { self.error = "Semantic search is unavailable. Keyword results are still shown. " + error.localizedDescription }
        }
    }
    func generateDesignPrompt(_ note: LibraryNote) async {
        guard !working, !demo, let repo = repository else { serviceMessage = "Example mode does not send references to a model."; return }
        working = true; defer { working = false }
        do {
            let images = try await requestImages(note); try await consumeBudget(); let key = try await ai.apiKey()
            let alias = images.isEmpty ? (settings.textModel.isEmpty ? ai.connection.model : settings.textModel) : settings.visionModel
            let prompt = try await LibraryAIClient().designPrompt(note, images: images, connection: LiteLLMConnection(baseURL: ai.connection.baseURL, model: alias), key: key)
            var generated = LibraryNote(title: "Design prompt · " + String(note.displayTitle.prefix(80)), prompt: prompt, sourceURL: note.sourceURL, originals: [LibraryOriginal(text: "", prompt: prompt, channel: "explicit-design-generation")])
            generated.automationAllowed = false; generated.kinds = [.design, .prompt]
            let saved = try await Task.detached { try repo.saveLibrary(generated, expectedRevision: nil, message: "Save explicitly generated design prompt") }.value
            accept(saved); selectedID = saved.id; scheduleBackup()
        } catch { self.error = error.localizedDescription }
    }
    private func saveJobs() async { guard let repo = repository else { return }; let value = jobs; do { try await Task.detached { try Self.write(value, file: repo.localState.appendingPathComponent("library-jobs.json")) }.value } catch { self.error = "Background job state could not be saved. Notes remain committed; retry jobs after storage is available." } }
    private func saveIndex() async { guard let repo = repository else { return }; let value = derived; do { try await Task.detached { try Self.write(value, file: repo.localState.appendingPathComponent("library-index.json")) }.value } catch { serviceMessage = "The local index could not be saved. Keyword search still reads original notes." } }
}
