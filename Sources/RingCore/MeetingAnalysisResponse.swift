import Foundation

/// Safe diagnostics only: never include generated content or transcript text in errors.
public struct MeetingAnalysisResponseError: LocalizedError, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case envelope = "unreadable response envelope", refused = "response declined", truncated = "response exceeded its output limit"
        case json = "incomplete JSON", limits = "response exceeded field limits"
        case taskFields = "invalid task fields", taskEvidence = "invalid task references", taskSpeaker = "invalid speaker reference"
        case topicFields = "invalid topic fields", topicEvidence = "invalid topic references"
    }
    public let reason: Reason
    public var retryable: Bool { reason != .refused }
    public init(_ reason: Reason) { self.reason = reason }
    public var errorDescription: String? {
        "Summary and task extraction returned \(reason.rawValue). Your transcript and completed results are saved; resume processing to continue without uploading audio again."
    }
}

/// Short request-local references reduce output size and copying mistakes. Durable
/// evidence and speaker identities are restored before anything reaches storage.
struct MeetingAnalysisReferences {
    let segments: [MeetingSegment]
    private let evidence: [String: String]
    private let speakers: [String: String]
    init(_ originals: [MeetingSegment]) {
        var evidence: [String: String] = [:], speakers: [String: String] = [:], reverseSpeakers: [String: String] = [:]
        var segments: [MeetingSegment] = []
        for (index, original) in originals.enumerated() {
            let id = "e\(index + 1)"
            let speaker = reverseSpeakers[original.speakerID] ?? "p\(reverseSpeakers.count + 1)"
            evidence[id] = original.id; speakers[speaker] = original.speakerID; reverseSpeakers[original.speakerID] = speaker
            var segment = original; segment.id = id; segment.speakerID = speaker; segments.append(segment)
        }
        self.segments = segments; self.evidence = evidence; self.speakers = speakers
    }
    func restoring(_ part: MeetingAnalysisPart) throws -> MeetingAnalysisPart {
        func ids(_ values: [String]) throws -> [String] {
            try values.map { guard let id = evidence[$0] else { throw MeetingAnalysisResponseError(.taskEvidence) }; return id }
        }
        let tasks = try part.tasks.map { task in
            var task = task; task.evidenceIDs = try ids(task.evidenceIDs)
            if let speaker = task.speakerID {
                guard let original = speakers[speaker] else { throw MeetingAnalysisResponseError(.taskSpeaker) }
                task.speakerID = original
            }
            return task
        }
        let topics = try part.topics.map { try MeetingTopic(title: $0.title, summary: $0.summary, evidenceIDs: ids($0.evidenceIDs)) }
        return MeetingAnalysisPart(summary: part.summary, decisions: part.decisions, tasks: tasks, topics: topics)
    }
}
