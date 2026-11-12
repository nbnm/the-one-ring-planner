import SwiftUI
import AppKit
import AVFoundation
import Combine
import CryptoKit
import RingCore

@MainActor final class MeetingStore: ObservableObject {
    @Published var recordings: [MeetingRecording] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { playback.reset(); transcriptTargetID = nil } } }
    @Published var showSetup = false
    @Published var showModels = false
    @Published var showSpeakers = false
    @Published var showRetranscription = false
    @Published var showTranscriptVersions = false
    @Published var retranscriptionModel = ""
    @Published var retranscriptionLanguage = MeetingLanguage.automatic
    @Published var retranscriptionSpeakerLabels = true
    @Published var retranscriptionError: String?
    private var useDraftForCloud = false
    @Published var uploadAudio = false
    @Published var showCloudConfirmation = false
    @Published var error: String?
    @Published var status = ""
    @Published var processingProgress: Double?
    @Published private(set) var workingID: String?
    @Published private(set) var activeID: String?
    @Published private(set) var finishing = false
    @Published var topicsOnly = false
    @Published var transcriptTargetID: String?
    @Published var transcriptNavigationID = UUID()
    let playback = MeetingPlayback()
    var preparingPlayback: Bool { playback.preparing }
    @Published var audioModel: String { didSet { defaults.set(audioModel, forKey: "meeting.audioModel") } }
    @Published var speakerLabels: Bool { didSet { defaults.set(speakerLabels, forKey: "meeting.speakerLabels") } }
    @Published var models: [MeetingModel] = []
    @Published var discovering = false
    @Published var discoveryMessage: String?
    let recorder = MeetingRecorder()
    let ai: CaptureAISettings
    let repository: MeetingRepository?
    let demo: Bool
    var importTasks: ((MeetingTaskImport) -> Bool)?
    var planningSettings: () -> PlanningSettings = { PlanningSettings() }
    var knownTags: () -> [String] = { [] }
    private let defaults: UserDefaults
    private var captureTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var checkpoint: Timer?
    private var updates: AnyCancellable?
    private var playbackUpdates: AnyCancellable?
    var selected: MeetingRecording? { recordings.first { $0.id == selectedID } }
    var busy: Bool { activeID != nil || workingID != nil || finishing || preparingPlayback }
    var gateway: String { URL(string: ai.connection.baseURL)?.host ?? "your saved LiteLLM gateway" }
    var recommendation: String {
        if let model = models.first(where: \.isDiarizationCandidate) { return "Suggested: \(model.id). Its alias indicates speaker separation; a sample recording will verify that your gateway supports diarized_json." }
        if let model = models.first(where: { $0.mode == "audio_transcription" }) { return "Suggested for transcription: \(model.id). The catalog does not confirm speaker separation; leave speaker labels off unless the gateway supports diarized_json." }
        if let model = models.first(where: \.isAudioCandidate) { return "Possible audio model: \(model.id). This is inferred from its alias. Audio and speaker-label support need a sample test." }
        return "No audio transcription alias was advertised. Use local English/Russian transcription and the saved text model for tasks, or ask the gateway administrator to expose an audio transcription model with speaker separation."
    }
    init(root: URL, ai: CaptureAISettings, demo: Bool) {
        self.ai = ai; self.demo = demo
        defaults = demo ? UserDefaults(suiteName: "com.t1a.meeting-demo.\(UUID().uuidString)")! : .standard
        audioModel = defaults.string(forKey: "meeting.audioModel") ?? ""
        speakerLabels = defaults.object(forKey: "meeting.speakerLabels") as? Bool ?? true
        var repo: MeetingRepository?
        do { repo = try MeetingRepository(root: root); let loaded = try repo!.load(); recordings = loaded; selectedID = loaded.first?.id }
        catch { self.error = error.localizedDescription }
        repository = repo
        playbackUpdates = playback.$preparing.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
        updates = recorder.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        recorder.onInterruption = { [weak self] message in Task { @MainActor in await self?.stopRecording(reason: message.localizedDescription) } }
        if demo && (CommandLine.arguments.contains("--meeting-demo") || CommandLine.arguments.contains("--middle-earth-demo")) { seedExample() }
    }
    @discardableResult private func save(_ record: MeetingRecording) -> Bool {
        do {
            guard let repository else { throw MeetingError.storage }
            try repository.save(record)
            if let index = recordings.firstIndex(where: { $0.id == record.id }) { recordings[index] = record }
            else { recordings.insert(record, at: 0) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func edit(_ id: String, _ change: (inout MeetingRecording) -> Void) {
        guard var record = recordings.first(where: { $0.id == id }), record.id != workingID else { return }
        change(&record); _ = save(record)
    }
    func start(title: String, language: MeetingLanguage, source: MeetingAudioSource) {
        guard !busy, let repository else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = MeetingRecording(title: clean.isEmpty ? "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))" : String(clean.prefix(160)), language: language, source: source)
        guard save(record) else { return }
        selectedID = record.id; activeID = record.id; showSetup = false; error = nil; stopPlayback()
        AppActions.prepareMeetingCapture()
        SpeechCapture.microphoneReservedForMeeting = source.includesMicrophone
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start(folder: repository.folder(record.id), source: source, example: demo)
                try Task.checkCancellation()
                checkpoint = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    Task { @MainActor in guard let self, let id = self.activeID, var item = self.recordings.first(where: { $0.id == id }) else { return }; item.duration = self.recorder.elapsed; _ = self.save(item) }
                }
            } catch {
                guard !finishing else { return }
                var item = recordings.first { $0.id == record.id } ?? record
                item.duration = max(item.duration, recorder.elapsed)
                item.state = .interrupted; item.endedAt = Date(); item.lastError = error is CancellationError ? "Recording cancelled. Any captured audio is preserved." : error.localizedDescription
                _ = save(item); activeID = nil; SpeechCapture.microphoneReservedForMeeting = false
            }
        }
    }
    func stopRecording(reason: String? = nil) async {
        guard let id = activeID, !finishing else { return }
        finishing = true; checkpoint?.invalidate(); checkpoint = nil
        captureTask?.cancel(); recorder.cancelPreparation(); await captureTask?.value; captureTask = nil
        let stats = await recorder.stop()
        SpeechCapture.microphoneReservedForMeeting = false
        if var record = recordings.first(where: { $0.id == id }) {
            record.duration = max(record.duration, stats.duration); record.endedAt = Date()
            record.state = reason == nil && record.duration > 0 ? .recorded : .interrupted
            record.lastError = reason ?? (record.duration > 0 ? nil : "No audio was captured. Check the selected app and microphone permissions.")
            if record.source.includesMicrophone && stats.microphoneFrames == 0 && reason == nil { record.lastError = "No microphone audio arrived. Other captured audio is saved. Check your input device in System Settings → Sound, then try again." }
            if record.source.includesCall && stats.callFrames == 0 { record.lastError = record.source.usesSystemAudio ? "No system audio arrived. Your microphone audio, if present, is saved. Check System Audio Recording permission and that sound is playing." : "No call audio arrived. Your microphone audio, if present, is saved. Check the app selected in the macOS picker." }
            _ = save(record)
        }
        activeID = nil; finishing = false
    }
    func shutdown() async { await stopRecording(); processingTask?.cancel(); await processingTask?.value; playback.reset() }
    func cancelProcessing() { processingTask?.cancel(); status = "Cancelling; keeping saved results…" }
    private func process(_ id: String, versionID: String? = nil, operation: @escaping () async throws -> Void) {
        guard !busy else { return }; workingID = id; error = nil; processingProgress = nil
        processingTask = Task { [weak self] in
            guard let self else { return }
            do { try await operation() }
            catch {
                do { try commitProcessing(id, versionID: versionID) { record in
                    record.state = .interrupted
                    record.lastError = error is CancellationError || (error as? URLError)?.code == .cancelled ? "Processing cancelled. Saved audio and completed results are preserved." : error.localizedDescription
                } } catch { self.error = error.localizedDescription }
            }
            workingID = nil; processingTask = nil; status = ""; processingProgress = nil
        }
    }
    private func commit(_ id: String, _ change: (inout MeetingRecording) -> Void) throws {
        guard var record = recordings.first(where: { $0.id == id }) else { throw MeetingError.storage }
        change(&record); guard save(record) else { throw MeetingError.storage }
    }
    private func processingRecord(_ id: String, versionID: String?) throws -> MeetingRecording {
        guard let original = recordings.first(where: { $0.id == id }) else { throw MeetingError.storage }
        return try versionID.map { try MeetingTranscriptVersions.working(original, id: $0) } ?? original
    }
    private func commitProcessing(_ id: String, versionID: String?, _ change: (inout MeetingRecording) -> Void) throws {
        if let versionID {
            guard let original = recordings.first(where: { $0.id == id }) else { throw MeetingError.storage }
            guard save(try MeetingTranscriptVersions.updating(original, id: versionID, change: change)) else { throw MeetingError.storage }
        } else { try commit(id, change) }
    }
    func requestRetranscription() {
        guard let record = selected, !busy else { return }
        let currentModel = record.audioConfiguration != nil && record.audioConfiguration != "local" ? record.transcriptModel : nil
        retranscriptionModel = record.retranscription?.model ?? currentModel ?? (audioModel.isEmpty && demo ? "example-transcription" : audioModel)
        retranscriptionLanguage = record.retranscription?.content.language ?? record.language
        retranscriptionSpeakerLabels = record.retranscription?.speakerLabels ?? speakerLabels
        retranscriptionError = nil; showRetranscription = true
    }
    func startRetranscription() {
        guard let record = selected, !busy else { return }
        do {
            let updated = try MeetingTranscriptVersions.begin(record, model: retranscriptionModel, language: retranscriptionLanguage,
                speakerLabels: retranscriptionSpeakerLabels, connection: demo ? .init(baseURL: "https://example.invalid/v1", model: "example-text") : ai.connection)
            guard save(updated) else { return }
            showRetranscription = false; useDraftForCloud = true; uploadAudio = true; topicsOnly = false; processCloud()
        } catch { retranscriptionError = error.localizedDescription }
    }
    func resumeRetranscription() {
        guard let draft = selected?.retranscription, !busy else { return }
        guard demo || draft.baseURL == ai.connection.baseURL else { error = "The gateway changed. Use Re-transcribe to start a new version with the current connection."; return }
        useDraftForCloud = true; uploadAudio = draft.content.processingPhase != .analysis; topicsOnly = false; showCloudConfirmation = true
    }
    func restoreTranscript(_ versionID: String) {
        guard let record = selected, !busy else { return }
        do { let restored = try MeetingTranscriptVersions.restore(record, versionID: versionID); if save(restored) { showTranscriptVersions = false } }
        catch { self.error = error.localizedDescription }
    }
    var cloudAudioModel: String { useDraftForCloud ? selected?.retranscription?.model ?? audioModel : audioModel }
    var cloudTextModel: String { useDraftForCloud ? selected?.retranscription?.textModel ?? ai.connection.model : ai.connection.model }
    var cloudGateway: String { URL(string: useDraftForCloud ? selected?.retranscription?.baseURL ?? ai.connection.baseURL : ai.connection.baseURL)?.host ?? gateway }
    func transcribeLocally() {
        guard let record = selected, record.importedTaskCount == 0, let repository else { return }
        process(record.id) { [self] in
            try commit(record.id) { $0.state = .transcribing; $0.lastError = nil; $0.processingPhase = nil }
            let segments = try await MeetingLocalTranscriber.transcribe(folder: repository.folder(record.id), language: record.language) { [weak self] in self?.status = $0 }
            try Task.checkCancellation()
            guard !segments.isEmpty else { throw MeetingError.validation("No speech was recognized. The audio is preserved; try the other language or a LiteLLM audio model.") }
            try commit(record.id) {
                if !record.segments.isEmpty {
                    var versions = $0.transcriptVersions ?? []; versions.append(MeetingTranscriptVersion(record)); $0.transcriptVersions = versions
                    $0.activeTranscriptVersionID = UUID().uuidString.lowercased()
                }
                $0.resetSpeakerAssignments()
                $0.segments = segments; $0.completedAudioParts = []; $0.audioConfiguration = "local"; $0.summaries = []; $0.decisions = []; $0.suggestions = []; $0.topics = nil; $0.state = .recorded
                $0.transcriptionNotice = "Local transcription labels your microphone and the call channel. It cannot distinguish individual call participants."
                $0.analysisProgress = nil; $0.processingPhase = nil
            }
        }
    }
    func requestCloud(audio: Bool) {
        guard selected != nil, !busy else { return }
        if audio && audioModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showModels = true; return }
        useDraftForCloud = false; topicsOnly = false; uploadAudio = audio; showCloudConfirmation = true
    }
    func requestTopicTimeline() {
        guard let selected, !selected.segments.isEmpty, !busy else { return }
        useDraftForCloud = false; topicsOnly = true; uploadAudio = false; showCloudConfirmation = true
    }
    func resumeCloud() {
        guard let selected, !busy else { return }
        if selected.processingPhase == .topics { requestTopicTimeline() }
        else { requestCloud(audio: selected.processingPhase == .transcription || (selected.processingPhase == nil && selected.analysisProgress == nil)) }
    }
    func processCloud() {
        guard let original = selected, let repository else { return }
        let draft = useDraftForCloud ? original.retranscription : nil, versionID = draft?.id
        guard let record = try? processingRecord(original.id, versionID: versionID) else { return }
        if demo, let versionID { processExampleRevision(original, versionID: versionID); return }
        let indexingTopics = topicsOnly
        let audio = uploadAudio, alias = draft?.model ?? audioModel
        let labels = draft?.speakerLabels ?? MeetingTranscriptionOptions.resolve(model: audioModel, speakerLabels: speakerLabels).speakerSeparation
        let connection = draft.map { LiteLLMConnection(baseURL: $0.baseURL, model: $0.textModel) } ?? ai.connection
        let tags = knownTags()
        process(record.id, versionID: versionID) { [self] in
            let key = try await ai.apiKey(), client = MeetingProcessingClient()
            if audio {
                guard record.importedTaskCount == 0 else { throw MeetingError.validation("This meeting already has imported tasks. Its transcript is kept to preserve their evidence.") }
                try commitProcessing(record.id, versionID: versionID) { $0.state = .transcribing; $0.lastError = nil; $0.processingPhase = .transcription }
                status = "Preparing short audio chunks…"; processingProgress = 0
                let folder = try repository.folder(record.id)
                let config = "\(connection.baseURL)|\(alias)|\(labels)|\(record.language.rawValue)"
                var sameConfig = record.audioConfiguration == config
                let completed = sameConfig ? record.completedAudioParts : []
                let planning = Task.detached { (try MeetingAudioMixer.transcriptionFrameCount(folder: folder), try MeetingAudioMixer.transcriptionChunks(folder: folder, completed: completed)) }
                let (total, initialChunks) = try await withTaskCancellationHandler { try await planning.value } onCancel: { planning.cancel() }
                var chunks = initialChunks
                while !chunks.isEmpty {
                    try Task.checkCancellation()
                    let chunk = chunks.removeFirst()
                    let currentCompleted = sameConfig ? (try processingRecord(record.id, versionID: versionID)).completedAudioParts : []
                    processingProgress = 0.8 * MeetingChunkPlanner.completedFraction(totalFrames: total, completed: currentCompleted)
                    let range = "\(MeetingTaskImport.timestamp(chunk.offset))–\(MeetingTaskImport.timestamp(chunk.offset + chunk.duration))"
                    status = "Transcribing \(range) · \(Int((processingProgress ?? 0) / 0.8 * 100))%"
                    let preparation = Task.detached { try MeetingAudioMixer.transcriptionPart(folder: folder, chunk: chunk) }
                    let part = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                    let result: MeetingTranscriptPart
                    do {
                        result = try await client.transcribe(file: part.url, partID: part.id, offset: part.offset, duration: part.duration,
                            language: record.language, speakerLabels: labels, connection: connection, audioModel: alias, apiKey: key,
                            timeoutAttempts: chunk.split == nil ? 3 : 1, onRetry: { [weak self] attempt, delay in
                                guard let self else { return }
                                await self.reportRetry(record.id, label: "Audio \(range)", attempt: attempt, delay: delay)
                            })
                    } catch {
                        try Task.checkCancellation()
                        if MeetingRetryPolicy.isTimeout(error), let smaller = chunk.split {
                            chunks.insert(contentsOf: smaller, at: 0)
                            status = "Retrying \(range) in smaller chunks…"
                            continue
                        }
                        throw error
                    }
                    try commitProcessing(record.id, versionID: versionID) { item in
                        if !sameConfig {
                            item.resetSpeakerAssignments()
                            item.segments = []; item.completedAudioParts = []; item.audioConfiguration = config
                            item.suggestions = []; item.summaries = []; item.decisions = []; item.topics = nil; item.analysisProgress = nil
                        }
                        item.segments += result.segments; item.completedAudioParts.append(part.id)
                        item.transcriptionNotice = !labels ? (MeetingTranscriptionOptions.resolve(model: alias, speakerLabels: false).note ?? "Individual speaker labels were not requested.") : (!result.hasSpeakerLabels
                            ? "Some audio chunks did not return speaker labels."
                            : "Speaker labels restart per audio chunk. Rename them in Transcript; identities are not assumed across chunks.")
                    }
                    sameConfig = true
                }
            }
            let latest = try processingRecord(record.id, versionID: versionID)
            guard !latest.segments.isEmpty else { throw MeetingError.validation("No speech was found. Your recording is preserved.") }
            let checkpoint = MeetingAnalysisCheckpoint.configuration(meeting: latest, knownTags: tags, connection: connection, topicsOnly: indexingTopics)
            try commitProcessing(record.id, versionID: versionID) {
                $0 = MeetingAnalysisCheckpoint.starting($0, configuration: checkpoint, restart: record.state == .ready)
                $0.state = .analyzing; $0.lastError = nil; $0.processingPhase = indexingTopics ? .topics : .analysis
            }
            let batches = MeetingProcessingClient.batches(latest.segments)
            for (index, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let batchID = MeetingAnalysisCheckpoint.batchID(batch)
                processingProgress = (audio ? 0.8 : 0) + (audio ? 0.2 : 1) * Double(index) / Double(max(1, batches.count))
                if (try processingRecord(record.id, versionID: versionID)).analysisProgress?.completedBatchIDs.contains(batchID) == true { continue }
                status = "Summary & tasks · \(index + 1) of \(batches.count)"
                let result = try await client.analyze(batch, meeting: latest, knownTags: tags, connection: connection, apiKey: key,
                    onRetry: { [weak self] attempt, delay in
                        guard let self else { return }
                        await self.reportRetry(record.id, label: "Summary \(index + 1)/\(batches.count)", attempt: attempt, delay: delay)
                    })
                try commitProcessing(record.id, versionID: versionID) { $0 = MeetingAnalysisCheckpoint.applying(result, batchID: batchID, topicsOnly: indexingTopics, to: $0) }
            }
            try commitProcessing(record.id, versionID: versionID) {
                if indexingTopics { $0.topics = $0.analysisProgress?.pendingTopics ?? [] }
                $0.state = .ready; $0.lastError = nil; $0.processingPhase = nil
            }
            if let versionID {
                let current = recordings.first { $0.id == record.id }!
                guard save(try MeetingTranscriptVersions.complete(current, id: versionID)) else { throw MeetingError.storage }
            }
            processingProgress = 1
        }
    }
    private func processExampleRevision(_ original: MeetingRecording, versionID: String) {
        process(original.id, versionID: versionID) { [self] in
            try commitProcessing(original.id, versionID: versionID) { $0.state = .transcribing; $0.lastError = nil }
            status = "Example transcription · no audio uploaded"; processingProgress = 0.2
            try await Task.sleep(nanoseconds: 3_000_000_000); try Task.checkCancellation()
            try commitProcessing(original.id, versionID: versionID) { record in
                record.segments = original.segments.map { segment in var segment = segment; segment.id = versionID + "-" + segment.id; return segment }
                record.audioConfiguration = "https://example.invalid/v1|\(record.retranscription?.model ?? retranscriptionModel)|\(record.retranscription?.speakerLabels ?? true)|\(record.language.rawValue)"
                record.completedAudioParts = ["stt-0-\(Int(record.duration * 16000))"]
                record.summaries = ["Example revised transcript and summary. No recording was uploaded."]
                record.suggestions = record.segments.first.map { [MeetingTaskSuggestion(title: "Review the revised transcript", evidenceIDs: [$0.id])] } ?? []
                record.transcriptionNotice = "Synthetic example revision. No microphone, call or cloud request was used."
                record.state = .ready; record.processingPhase = nil
            }
            let current = recordings.first { $0.id == original.id }!
            guard save(try MeetingTranscriptVersions.complete(current, id: versionID)) else { throw MeetingError.storage }
            processingProgress = 1
        }
    }
    private func reportRetry(_ id: String, label: String, attempt: Int, delay: Double) {
        guard workingID == id else { return }
        status = "\(label) · retry \(attempt)/3 in \(Int(delay))s"
    }
    func addSelectedTasks() {
        guard let record = selected, !busy else { return }
        do {
            let receipt = try record.pendingTaskImport ?? MeetingTaskImport(meeting: record, settings: planningSettings(), knownTags: knownTags())
            try commit(record.id) { $0.pendingTaskImport = receipt }
            guard importTasks?(receipt) == true else { throw MeetingError.validation("Tasks could not be saved to the planner. Your reviewed selection is preserved; retry when storage is available.") }
            try finishReceipt(record.id, receipt)
            status = "\(receipt.tasks.count) \(receipt.tasks.count == 1 ? "task" : "tasks") added to Inbox."
        } catch { self.error = error.localizedDescription }
    }
    private func finishReceipt(_ id: String, _ receipt: MeetingTaskImport) throws {
        try commit(id) { record in
            for i in record.suggestions.indices {
                if let index = receipt.proposalIDs.firstIndex(of: record.suggestions[i].id) { record.suggestions[i].savedTaskID = receipt.tasks[index].id; record.suggestions[i].included = false }
            }
            record.pendingTaskImport = nil
        }
    }
    func recoverImports() {
        for record in recordings {
            if let receipt = record.pendingTaskImport, importTasks?(receipt) == true { do { try finishReceipt(record.id, receipt) } catch { self.error = error.localizedDescription } }
        }
    }
    func discoverModels() {
        guard !discovering else { return }; discovering = true; discoveryMessage = nil
        Task {
            defer { discovering = false }
            do {
                let key = try await ai.apiKey()
                models = try await MeetingProcessingClient().models(connection: ai.connection, apiKey: key)
                discoveryMessage = "\(models.count) available aliases. \(recommendation)"
            } catch { discoveryMessage = error.localizedDescription }
        }
    }
    func preparePlayback(_ record: MeetingRecording) {
        guard activeID == nil, playback.recordingID != record.id, let folder = try? repository?.folder(record.id) else { return }
        playback.load(recordingID: record.id, folder: folder, estimatedDuration: record.duration)
    }
    func play(_ record: MeetingRecording, at seconds: Double = 0) {
        guard activeID == nil, let folder = try? repository?.folder(record.id) else { return }
        playback.load(recordingID: record.id, folder: folder, estimatedDuration: record.duration, at: seconds, autoplay: true)
    }
    func navigate(_ record: MeetingRecording, segmentID: String) {
        guard let segment = record.segments.first(where: { $0.id == segmentID }) else { return }
        transcriptTargetID = segmentID; transcriptNavigationID = UUID(); play(record, at: segment.start)
    }
    func showCurrentPassage(_ record: MeetingRecording) {
        guard let segment = MeetingNavigation.nearest(at: playback.position, segments: record.segments) else { return }
        transcriptTargetID = segment.id; transcriptNavigationID = UUID()
    }
    func stopPlayback() { playback.reset() }
    func reveal(_ record: MeetingRecording) { if let url = try? repository?.folder(record.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func export(_ record: MeetingRecording) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(record.title.replacingOccurrences(of: "/", with: "-")) transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (record.title + "\n\n" + record.summaries.joined(separator: "\n\n") + "\n\n" + record.transcript).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
    func trash(_ record: MeetingRecording) {
        guard !busy, let folder = try? repository?.folder(record.id) else { return }
        if playback.recordingID == record.id { playback.reset() }
        NSWorkspace.shared.recycle([folder]) { [weak self] _, error in Task { @MainActor in
            guard let self else { return }
            if let error { self.error = error.localizedDescription }
            else { self.recordings.removeAll { $0.id == record.id }; self.selectedID = self.recordings.first?.id }
        } }
    }
    private func seedExample() {
        var record = MeetingRecording(title: "T1A · Product planning", language: .english, source: .callAndMicrophone)
        record.state = .ready; record.duration = 132; record.endedAt = Date()
        record.segments = [
            MeetingSegment(id: "example1", start: 4, end: 15, speakerID: "part-001:A", text: "I'll review the 8FDE proposal and send the updated estimate on Friday."),
            MeetingSegment(id: "example2", start: 20, end: 32, speakerID: "part-001:B", text: "Я подготовлю список вопросов для следующей встречи по продукту."),
            MeetingSegment(id: "example3", start: 40, end: 56, speakerID: "part-001:A", text: "For the product demo, let's show the calendar timeline and the new recording controls."),
            MeetingSegment(id: "example4", start: 63, end: 78, speakerID: "part-001:B", text: "В демо покажем поиск по расшифровке и переход к нужной части разговора."),
            MeetingSegment(id: "example5", start: 88, end: 105, speakerID: "part-001:A", text: "The delivery plan needs an owner for the rollout. I'll draft the checklist before our next call."),
            MeetingSegment(id: "example6", start: 112, end: 128, speakerID: "part-001:B", text: "Проверим план запуска и сроки на следующей встрече. На сегодня всё.")]
        record.speakerNames = ["part-001:A": "Oleg", "part-001:B": "Alex"]
        record.topics = [MeetingTopic(title: "8FDE proposal & estimate", summary: "Review the proposal, estimate and follow-up questions.", evidenceIDs: ["example1", "example2"]),
            MeetingTopic(title: "Product demo · Демо продукта", summary: "Calendar navigation, playback and transcript search.", evidenceIDs: ["example3", "example4"]),
            MeetingTopic(title: "Delivery plan & next steps", summary: "Rollout checklist, ownership and the next meeting.", evidenceIDs: ["example5", "example6"])]
        record.summaries = ["The team reviewed the proposal and agreed on follow-up work for the next product meeting."]
        record.suggestions = [MeetingTaskSuggestion(title: "Review the 8FDE proposal and send the estimate", tags: ["8FDE"], speakerID: "part-001:A", timing: "Friday", evidenceIDs: ["example1"]), MeetingTaskSuggestion(title: "Подготовить вопросы для встречи по продукту", tags: ["Product"], speakerID: "part-001:B", evidenceIDs: ["example2"])]
        if CommandLine.arguments.contains("--meeting-speaker-demo") {
            record.suggestions.insert(MeetingTaskSuggestion(title: "Review the shared follow-up", evidenceIDs: ["example6"]), at: 1)
        }
        if CommandLine.arguments.contains("--meeting-retranscription-demo") {
            record.audioConfiguration = "https://example.invalid/v1|original-model|true|english"
            record.completedAudioParts = ["part-001"]
            record.suggestions[0].savedTaskID = "example-imported-task"; record.suggestions[0].included = false
        }
        if CommandLine.arguments.contains("--middle-earth-demo") { record = middleEarthMeeting(record) }
        record.transcriptionNotice = "Example transcript with synthetic test tones, not recorded speech. No actual meeting was recorded or uploaded."
        _ = save(record); selectedID = record.id
        // Playable, quiet test tones exercise the complete timeline without accessing a microphone.
        if let folder = try? repository?.folder(record.id) {
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: folder.appendingPathComponent("microphone.caf"), settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                let total = Int(record.duration * 16000)
                var frame = 0
                while frame < total {
                    let count = min(4096, total - frame); buffer.frameLength = AVAudioFrameCount(count)
                    for i in 0..<count { let t = Double(frame + i) / 16000; buffer.floatChannelData![0][i] = Float(sin(t * 2 * .pi * 220) * (Int(t).isMultiple(of: 4) ? 0.012 : 0)) }
                    try file.write(from: buffer); frame += count
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
