import Foundation
import RingCore

struct MeetingNavigationTests {
    var segments: [MeetingSegment] { [
        .init(id: "a", start: 10, end: 20, speakerID: "A", text: "Review the café proposal for T1A."),
        .init(id: "b", start: 25, end: 40, speakerID: "B", text: "Проверим план запуска продукта."),
        .init(id: "c", start: 30, end: 45, speakerID: "A", text: "The product launch needs a plan.") ] }
    func testBilingualSearchAndSpeakerFiltering() {
        XCTAssertEqual(MeetingNavigation.matching(segments, query: "cafe").map(\.id), ["a"])
        XCTAssertEqual(MeetingNavigation.matching(segments, query: "ПЛАН").map(\.id), ["b"])
        XCTAssertEqual(MeetingNavigation.matching(segments, query: "plan", speaker: "A").map(\.id), ["c"])
        XCTAssertTrue(MeetingNavigation.matching(segments, query: "unknown").isEmpty)
        XCTAssertEqual(MeetingNavigation.matching(segments.reversed(), query: "  ").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(MeetingNavigation.activeIDs(at: 35, segments: segments), Set(["b", "c"]))
        XCTAssertTrue(MeetingNavigation.activeIDs(at: 20, segments: segments).isEmpty)
        XCTAssertEqual(MeetingNavigation.nearest(at: 22, segments: segments)?.id, "a")
    }
    func response(topics: [[String: Any]]) throws -> Data {
        let value: [String: Any] = ["summary": "Discussion", "decisions": [], "tasks": [], "topics": topics]
        return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)]]]])
    }
    func testTopicTimesAreDerivedOnlyFromCitedEvidence() throws {
        let data = try response(topics: [["title": "T One A launch", "summary": "Plan with eight F D E", "evidence_segment_ids": ["c", "b", "c"], "start": 9999, "end": 99999]])
        let result = try MeetingProcessingClient.parseAnalysis(data, segments: segments, knownTags: [])
        XCTAssertEqual(result.topics.count, 1)
        XCTAssertEqual(result.topics[0].title, "T1A launch"); XCTAssertEqual(result.topics[0].summary, "Plan with 8FDE")
        XCTAssertEqual(result.topics[0].evidenceIDs, ["b", "c"])
        let ranges = MeetingNavigation.topics(result.topics, segments: segments)
        XCTAssertEqual(ranges.first?.start, 25); XCTAssertEqual(ranges.first?.end, 45); XCTAssertEqual(ranges.first?.firstSegmentID, "b")
        XCTAssertEqual(MeetingNavigation.topics(result.topics + result.topics, segments: segments).count, 1)
        XCTAssertThrowsError(try MeetingProcessingClient.parseAnalysis(response(topics: [["title":"Invented", "summary":"", "evidence_segment_ids":["unknown"]]]), segments: segments, knownTags: []))
        XCTAssertThrowsError(try MeetingProcessingClient.parseAnalysis(response(topics: [["title":"Empty", "summary":"", "evidence_segment_ids":[]]]), segments: segments, knownTags: []))
        XCTAssertTrue(MeetingNavigation.topics([MeetingTopic(title: "Missing", evidenceIDs: ["unknown"])], segments: segments).isEmpty)
    }
    func testLegacyRecordingsAndTopicIndexSurviveRestart() throws {
        var recording = MeetingRecording(title: "Existing recording", language: .russian, source: .call)
        recording.state = .ready; recording.duration = 50; recording.segments = segments
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(recording)) as! [String: Any]
        legacy.removeValue(forKey: "topics")
        let restored = try decoder.decode(MeetingRecording.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.segments, segments); XCTAssertEqual(restored.topics, nil)
        recording.topics = [MeetingTopic(title: "Launch", evidenceIDs: ["b", "c"])]
        let roundtrip = try decoder.decode(MeetingRecording.self, from: encoder.encode(recording))
        XCTAssertEqual(roundtrip, recording)
        XCTAssertEqual(roundtrip.transcript, recording.transcript)
    }
    func testAbsolutePlaybackBoundsAndPartBoundaries() {
        let ranges = [DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1200), DateInterval(start: Date(timeIntervalSince1970: 1200), duration: 1200), DateInterval(start: Date(timeIntervalSince1970: 2400), duration: 100)]
        XCTAssertEqual(MeetingNavigation.partIndex(at: 1199.9, ranges: ranges), 0)
        XCTAssertEqual(MeetingNavigation.partIndex(at: 1200, ranges: ranges), 1)
        XCTAssertEqual(MeetingNavigation.partIndex(at: 2500, ranges: ranges), 2)
        XCTAssertEqual(MeetingNavigation.partIndex(at: -10, ranges: ranges), 0)
        XCTAssertEqual(MeetingNavigation.partIndex(at: .nan, ranges: ranges), nil)
        XCTAssertEqual(MeetingNavigation.clampedPosition(-1, duration: 2500), 0)
        XCTAssertEqual(MeetingNavigation.clampedPosition(9000, duration: 2500), 2500)
        XCTAssertEqual(MeetingNavigation.clampedPosition(.infinity, duration: 2500), 0)
        XCTAssertEqual(MeetingTaskImport.timestamp(3699), "1:01:39")
    }
}
