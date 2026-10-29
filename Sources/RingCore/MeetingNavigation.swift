import Foundation
import CryptoKit

/// Topics cite transcript IDs. Their times are derived locally, never invented by a model.
public struct MeetingTopic: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var summary: String
    public var evidenceIDs: [String]
    public init(title: String, summary: String = "", evidenceIDs: [String]) {
        self.title = title; self.summary = summary; self.evidenceIDs = evidenceIDs
        id = SHA256.hash(data: Data((title + "|" + evidenceIDs.sorted().joined(separator: "|")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct MeetingTopicRange: Identifiable, Equatable, Sendable {
    public var id: String { topic.id }
    public let topic: MeetingTopic
    public let start: Double
    public let end: Double
    public let firstSegmentID: String
}
public enum MeetingNavigation {
    public static func ordered(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public static func matching(_ segments: [MeetingSegment], query: String, speaker: String = "") -> [MeetingSegment] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ordered(segments).filter { segment in
            (speaker.isEmpty || segment.speakerID == speaker) && (needle.isEmpty || segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }
    public static func activeIDs(at time: Double, segments: [MeetingSegment]) -> Set<String> {
        guard time.isFinite else { return [] }
        return Set(segments.filter { $0.start <= time && time < $0.end }.map(\.id))
    }
    public static func nearest(at time: Double, segments: [MeetingSegment]) -> MeetingSegment? {
        let values = ordered(segments)
        return values.last { $0.start <= time && time < $0.end } ?? values.last { $0.start <= time } ?? values.first
    }
    public static func topics(_ topics: [MeetingTopic], segments: [MeetingSegment]) -> [MeetingTopicRange] {
        var seen = Set<String>()
        let sources = Dictionary(ordered(segments).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return topics.compactMap { topic in
            guard !topic.evidenceIDs.isEmpty, topic.evidenceIDs.allSatisfy({ sources[$0] != nil }), seen.insert(topic.id).inserted else { return nil }
            let evidence = ordered(topic.evidenceIDs.compactMap { sources[$0] })
            return MeetingTopicRange(topic: topic, start: evidence[0].start, end: evidence.map(\.end).max()!, firstSegmentID: evidence[0].id)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public static func clampedPosition(_ seconds: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration, max(0, seconds.isFinite ? seconds : 0))
    }
    /// Exclusive part ends choose the next file at an exact boundary.
    public static func partIndex(at time: Double, ranges: [DateInterval]) -> Int? {
        guard !ranges.isEmpty, time.isFinite else { return nil }
        let t = Date(timeIntervalSince1970: max(0, time))
        return ranges.firstIndex { $0.start <= t && t < $0.end } ?? (t >= ranges.last!.end ? ranges.count - 1 : ranges.firstIndex { $0.start >= t })
    }
}
