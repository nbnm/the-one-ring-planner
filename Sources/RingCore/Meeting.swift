import Foundation
import CryptoKit

public enum MeetingLanguage: String, Codable, CaseIterable, Sendable {
    case automatic, english, russian
    public var title: String { switch self { case .automatic: return "Russian / English · auto"; case .english: return "English"; case .russian: return "Русский" } }
    public var code: String? { switch self { case .automatic: return nil; case .english: return "en"; case .russian: return "ru" } }
    public var locale: String? { switch self { case .automatic: return nil; case .english: return "en-US"; case .russian: return "ru-RU" } }
}
public enum MeetingAudioSource: String, Codable, CaseIterable, Sendable {
    case systemAndMicrophone, system, callAndMicrophone, microphone, call
    public var title: String { switch self {
    case .systemAndMicrophone: return "System audio + microphone"
    case .system: return "System audio only"
    case .callAndMicrophone: return "Selected app + microphone"
    case .microphone: return "Microphone only"
    case .call: return "Selected app only"
    } }
    public var includesMicrophone: Bool { self == .microphone || self == .callAndMicrophone || self == .systemAndMicrophone }
    public var includesCall: Bool { self != .microphone }
    public var usesSystemAudio: Bool { self == .system || self == .systemAndMicrophone }
}
public struct MeetingSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speakerID: String
    public var text: String
    public init(id: String = UUID().uuidString.lowercased(), start: Double, end: Double, speakerID: String, text: String) {
        self.id = id; self.start = start; self.end = end; self.speakerID = speakerID; self.text = text
    }
}
public struct MeetingTaskSuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var included = true
    public var title: String
    public var notes: String
    public var tags: [String]
    public var speakerID: String?
    public var timing: String
    public var evidenceIDs: [String]
    public var savedTaskID: String?
    public init(title: String, notes: String = "", tags: [String] = [], speakerID: String? = nil, timing: String = "", evidenceIDs: [String] = []) {
        id = UUID().uuidString.lowercased(); self.title = title; self.notes = notes; self.tags = tags
        self.speakerID = speakerID; self.timing = timing; self.evidenceIDs = evidenceIDs
    }
}
public struct MeetingTaskImport: Codable, Equatable, Sendable {
    public var proposalIDs: [String]
    public var tasks: [PlannerTask]
    public var capture: Capture
    public init(meeting: MeetingRecording, settings: PlanningSettings, knownTags: [String], now: Date = Date()) throws {
        let proposals = meeting.suggestions.filter { $0.included && $0.savedTaskID == nil }
        guard !proposals.isEmpty, proposals.count <= 60 else { throw MeetingError.validation("Select between 1 and 60 unsaved tasks.") }
        guard proposals.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 160 && $0.notes.count <= 8000 }) else {
            throw MeetingError.validation("Give each selected task a title of 160 characters or fewer.")
        }
        proposalIDs = proposals.map(\.id)
        tasks = proposals.map { proposal in
            let digest = SHA256.hash(data: Data("\(meeting.id)|\(proposal.id)".utf8)).map { String(format: "%02x", $0) }.joined()
            var notes = [proposal.notes]
            if let speaker = proposal.speakerID { notes.append("Owner: \(meeting.speakerName(speaker))") }
            if !proposal.timing.isEmpty { notes.append("Timing: \(proposal.timing)") }
            notes.append("Meeting: \(meeting.title)")
            let evidence = meeting.segments.filter { proposal.evidenceIDs.contains($0.id) }
            for segment in evidence.prefix(3) { notes.append("[\(Self.timestamp(segment.start))] \(meeting.speakerName(segment.speakerID)): \(segment.text.prefix(800))") }
            var task = PlannerTask(id: "meeting-" + digest, title: CaptureVocabulary.normalize(proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)),
                context: meeting.title, notes: notes.filter { !$0.isEmpty }.joined(separator: "\n"), tags: TaskTags.normalize(proposal.tags, known: knownTags), now: now)
            task.minimumBlockMinutes = settings.minimumFocusMinutes
            return task
        }
        // The full recording/transcript stays outside Git. Only reviewed task titles enter the capture ledger.
        capture = Capture(text: "Reviewed meeting tasks · \(meeting.title)\n" + tasks.map(\.title).joined(separator: "\n"), timeZone: settings.timeZone, taskIDs: tasks.map(\.id), now: now)
        for i in tasks.indices { tasks[i].sourceCaptureID = capture.id }
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
public enum MeetingProcessingPhase: String, Codable, Sendable { case transcription, analysis, topics }
public struct MeetingRecording: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, recorded, transcribing, analyzing, ready, interrupted }
    public var schemaVersion = 1
    public var id: String
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var duration: Double = 0
    public var language: MeetingLanguage
    public var source: MeetingAudioSource
    public var state = State.recording
    public var segments: [MeetingSegment] = []
    public var speakerNames: [String: String] = [:]
    public var speakerAliases: [MeetingSpeakerAlias]?
    public var speakerAliasAssignments: [String: String]?
    public var summaries: [String] = []
    public var decisions: [String] = []
    public var topics: [MeetingTopic]? = nil
    public var suggestions: [MeetingTaskSuggestion] = []
    public var lastError: String?
    public var transcriptionNotice: String?
    public var completedAudioParts: [String] = []
    public var audioConfiguration: String?
    public var analysisProgress: MeetingAnalysisProgress?
    public var processingPhase: MeetingProcessingPhase?
    public var pendingTaskImport: MeetingTaskImport?
    public var transcriptVersions: [MeetingTranscriptVersion]?
    public var activeTranscriptVersionID: String?
    public var retranscription: MeetingRetranscription?
    public init(id: String = UUID().uuidString.lowercased(), title: String, language: MeetingLanguage, source: MeetingAudioSource, now: Date = Date()) {
        self.id = id; self.title = title; self.language = language; self.source = source; createdAt = now
    }
    public func speakerName(_ id: String) -> String {
        if let alias = speakerAlias(for: id) { return alias.displayName }
        if let name = speakerNames[id], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if id == "me" { return "You · microphone" }
        if id == "call" { return "Call participants" }
        if id.hasSuffix(":unassigned") { return "Speaker unavailable" }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? "Speaker \(parts[1]) · \(parts[0])" : "Speaker \(id)"
    }
    public var isProcessing: Bool { state == .transcribing || state == .analyzing }
    public var importedTaskCount: Int { suggestions.filter { $0.savedTaskID != nil }.count }
    public var transcript: String {
        segments.sorted { $0.start < $1.start }.map { "[\(MeetingTaskImport.timestamp($0.start))] \(speakerName($0.speakerID)): \($0.text)" }.joined(separator: "\n")
    }
}
public enum MeetingError: LocalizedError {
    case validation(String), configuration, invalidResponse, http(Int), storage, tooLarge, cancelled
    public var errorDescription: String? {
        switch self {
        case .validation(let text): return text
        case .configuration: return "Set a meeting transcription model alias in Settings → The Eye. The alias must support audio transcription through your LiteLLM gateway."
        case .invalidResponse: return "The meeting model returned an invalid or incomplete response. Your recording and previous results are preserved."
        case .http(401), .http(403): return "The gateway refused this model or key. Check the meeting model alias and LiteLLM access."
        case .http(413): return "The gateway rejected the audio size. Your recording is preserved."
        case .http(429): return "The gateway rate or budget limit was reached. Your recording is preserved; retry later."
        case .http(let code): return "Meeting processing failed (HTTP \(code)). Your recording is preserved."
        case .storage: return "The meeting could not be saved. Check free disk space and folder access."
        case .tooLarge: return "This audio part exceeds the 24 MB upload limit. Prepare smaller audio parts before retrying."
        case .cancelled: return "Recording was cancelled."
        }
    }
}
