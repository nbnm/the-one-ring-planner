import Foundation

/// Transcript-only snapshots never nest recording history or duplicate original audio.
public struct MeetingTranscriptVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let savedAt: Date
    public let model: String
    public var language: MeetingLanguage
    public var state: MeetingRecording.State
    public var segments: [MeetingSegment]
    public var speakerNames: [String: String]
    public var speakerAliases: [MeetingSpeakerAlias]?
    public var speakerAliasAssignments: [String: String]?
    public var summaries: [String]
    public var decisions: [String]
    public var topics: [MeetingTopic]?
    public var suggestions: [MeetingTaskSuggestion]
    public var lastError: String?
    public var notice: String?
    public var completedAudioParts: [String]
    public var audioConfiguration: String?
    public var analysisProgress: MeetingAnalysisProgress?
    public var processingPhase: MeetingProcessingPhase?
    public init(_ recording: MeetingRecording, id: String? = nil, model: String? = nil, now: Date = Date()) {
        self.id = id ?? recording.activeTranscriptVersionID ?? UUID().uuidString.lowercased()
        savedAt = now; self.model = model ?? recording.transcriptModel
        language = recording.language; state = recording.state; segments = recording.segments
        speakerNames = recording.speakerNames; speakerAliases = recording.speakerAliases; speakerAliasAssignments = recording.speakerAliasAssignments
        summaries = recording.summaries; decisions = recording.decisions; topics = recording.topics; suggestions = recording.suggestions
        lastError = recording.lastError; notice = recording.transcriptionNotice; completedAudioParts = recording.completedAudioParts
        audioConfiguration = recording.audioConfiguration; analysisProgress = recording.analysisProgress; processingPhase = recording.processingPhase
    }
    public var hasContent: Bool { !segments.isEmpty || !summaries.isEmpty || !suggestions.isEmpty }
    public func applying(to recording: MeetingRecording) -> MeetingRecording {
        var result = recording
        result.language = language; result.state = state; result.segments = segments
        result.speakerNames = speakerNames; result.speakerAliases = speakerAliases; result.speakerAliasAssignments = speakerAliasAssignments
        result.summaries = summaries; result.decisions = decisions; result.topics = topics; result.suggestions = suggestions
        result.lastError = lastError; result.transcriptionNotice = notice; result.completedAudioParts = completedAudioParts
        result.audioConfiguration = audioConfiguration; result.analysisProgress = analysisProgress; result.processingPhase = processingPhase
        result.activeTranscriptVersionID = id
        return result
    }
}
public struct MeetingRetranscription: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let model: String
    public let speakerLabels: Bool
    public let baseURL: String
    public let textModel: String
    public var content: MeetingTranscriptVersion
}
extension MeetingRecording {
    public var transcriptModel: String {
        if audioConfiguration == "local" { return "On this Mac" }
        let fields = audioConfiguration?.split(separator: "|", omittingEmptySubsequences: false) ?? []
        return fields.count > 1 ? String(fields[1]) : "Previous transcript"
    }
}
public enum MeetingTranscriptVersions {
    public static func begin(_ original: MeetingRecording, model: String, language: MeetingLanguage, speakerLabels: Bool,
                             connection: LiteLLMConnection, now: Date = Date()) throws -> MeetingRecording {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 256, !model.contains(where: \.isNewline) else { throw MeetingError.validation("Choose an audio transcription model.") }
        guard original.pendingTaskImport == nil else { throw MeetingError.validation("Finish saving the reviewed tasks before starting another transcript.") }
        _ = try connection.endpoint()
        var result = original
        if let pending = original.retranscription, pending.content.hasContent {
            var partial = pending.content; partial.state = .interrupted
            var versions = result.transcriptVersions ?? []; versions.append(partial); result.transcriptVersions = versions
        }
        let id = UUID().uuidString.lowercased()
        var work = original
        work.language = language; work.state = .recorded; work.lastError = nil
        work.resetSpeakerAssignments(); work.segments = []; work.completedAudioParts = []; work.audioConfiguration = nil
        work.summaries = []; work.decisions = []; work.suggestions = []; work.topics = nil
        work.analysisProgress = nil; work.processingPhase = .transcription; work.transcriptionNotice = nil
        result.retranscription = .init(id: id, model: model, speakerLabels: MeetingTranscriptionOptions.resolve(model: model, speakerLabels: speakerLabels).speakerSeparation,
                                      baseURL: connection.baseURL, textModel: connection.model,
                                      content: .init(work, id: id, model: model, now: now))
        return result
    }
    public static func working(_ original: MeetingRecording, id: String) throws -> MeetingRecording {
        guard let draft = original.retranscription, draft.id == id else { throw MeetingError.validation("This transcription version is no longer active.") }
        return draft.content.applying(to: original)
    }
    public static func updating(_ original: MeetingRecording, id: String, change: (inout MeetingRecording) -> Void) throws -> MeetingRecording {
        var work = try working(original, id: id); change(&work)
        var result = original
        guard let draft = original.retranscription else { throw MeetingError.storage }
        result.retranscription?.content = .init(work, id: id, model: draft.model, now: draft.content.savedAt)
        return result
    }
    private static func preserveImports(_ result: inout MeetingRecording, sources: [MeetingTranscriptVersion]) {
        var imported: [String: String] = [:]
        for proposal in sources.flatMap(\.suggestions) { if let task = proposal.savedTaskID { imported[proposal.id] = task } }
        for i in result.suggestions.indices {
            if let task = imported[result.suggestions[i].id] { result.suggestions[i].savedTaskID = task; result.suggestions[i].included = false }
        }
    }
    public static func complete(_ original: MeetingRecording, id: String, now: Date = Date()) throws -> MeetingRecording {
        guard let draft = original.retranscription, draft.id == id, draft.content.state == .ready else { throw MeetingError.validation("Finish processing before using the new transcript.") }
        let current = MeetingTranscriptVersion(original, now: now)
        var versions = original.transcriptVersions ?? []
        if current.hasContent { versions.removeAll { $0.id == current.id }; versions.append(current) }
        var result = draft.content.applying(to: original)
        result.transcriptVersions = versions; result.retranscription = nil
        preserveImports(&result, sources: versions)
        return result
    }
    public static func restore(_ original: MeetingRecording, versionID: String, now: Date = Date()) throws -> MeetingRecording {
        guard original.pendingTaskImport == nil else { throw MeetingError.validation("Finish saving reviewed tasks before switching transcripts.") }
        var versions = original.transcriptVersions ?? []
        guard let target = versions.first(where: { $0.id == versionID }) else { throw MeetingError.validation("That transcript version is unavailable.") }
        let current = MeetingTranscriptVersion(original, now: now)
        versions.removeAll { $0.id == versionID || $0.id == current.id }
        if current.hasContent { versions.append(current) }
        var result = target.applying(to: original)
        result.transcriptVersions = versions
        preserveImports(&result, sources: versions + [target])
        return result
    }
}
