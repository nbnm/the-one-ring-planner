import Foundation
import RingCore

struct LongMeetingTests {
    let hour: Int64 = 3600 * 16000
    func testHourCoverageAndLegacyResume() {
        let chunks = MeetingChunkPlanner.pending(totalFrames: hour, completed: [])
        XCTAssertEqual(chunks.count, 20); XCTAssertEqual(chunks.first?.startFrame, 0); XCTAssertEqual(chunks.last?.endFrame, hour)
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 180 && $0.duration > 0 })
        XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0.endFrame == $1.startFrame })
        let pending = MeetingChunkPlanner.pending(totalFrames: hour, completed: ["part-001", "part-001"])
        XCTAssertEqual(pending.first?.offset, 1200); XCTAssertEqual(pending.reduce(0) { $0 + $1.duration }, 2400)
        XCTAssertTrue(MeetingChunkPlanner.pending(totalFrames: 377 * 16000, completed: ["part-001"]).isEmpty)
        XCTAssertTrue(abs(MeetingChunkPlanner.completedFraction(totalFrames: hour, completed: ["part-001"]) - 1.0 / 3.0) < 0.00001)
        XCTAssertEqual(MeetingChunkPlanner.pending(totalFrames: hour, completed: ["stt-0-999999999999", "part-9999", "bad"]).count, 20)
    }
    func testAdaptiveSplitsResumeOnlyUncoveredAudio() {
        let first = MeetingChunkPlanner.pending(totalFrames: hour, completed: [])[0]
        let halves = first.split!, quarters = halves[0].split!
        XCTAssertEqual(halves.map(\.duration), [90, 90]); XCTAssertEqual(quarters.map(\.duration), [45, 45]); XCTAssertTrue(quarters[0].split == nil)
        let pending = MeetingChunkPlanner.pending(totalFrames: hour, completed: [quarters[0].id, halves[1].id])
        XCTAssertEqual(pending.first?.offset, 45); XCTAssertEqual(pending.first?.duration, 45)
        XCTAssertEqual(pending.reduce(0) { $0 + $1.duration }, 3465)
        XCTAssertTrue(abs(MeetingChunkPlanner.completedFraction(totalFrames: hour, completed: [first.id, halves[0].id]) - 0.05) < 0.00001)
    }
    func testAnalysisIsBoundedAndCheckpointIsDurable() throws {
        let segments = (0..<200).map { MeetingSegment(id: "evidence-\($0)", start: Double($0 * 18), end: Double($0 * 18 + 17), speakerID: "A", text: String(repeating: "План T1A и 8FDE. ", count: 12)) }
        let batches = MeetingProcessingClient.batches(segments)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), segments.map(\.id))
        XCTAssertTrue(batches.allSatisfy { $0.count <= 40 && ($0.last!.end - $0.first!.start) <= 300 })
        XCTAssertTrue(batches.allSatisfy { $0.reduce(0) { $0 + $1.text.count + $1.id.count + $1.speakerID.count + 100 } <= 6000 })
        var record = MeetingRecording(title: "Hour fixture", language: .russian, source: .call); record.segments = segments
        let connection = LiteLLMConnection(baseURL: "https://gateway.example/v1", model: "working")
        let configuration = MeetingAnalysisCheckpoint.configuration(meeting: record, knownTags: ["T1A"], connection: connection, topicsOnly: false)
        record = MeetingAnalysisCheckpoint.starting(record, configuration: configuration, restart: false)
        let proposal = MeetingTaskSuggestion(title: "Review plan", evidenceIDs: [segments[0].id])
        let part = MeetingAnalysisPart(summary: "Fixture summary", decisions: ["Ship"], tasks: [proposal])
        let id = MeetingAnalysisCheckpoint.batchID(batches[0])
        record = MeetingAnalysisCheckpoint.applying(part, batchID: id, topicsOnly: false, to: record)
        record.processingPhase = .analysis
        record.suggestions[0].title = "User-reviewed title"; record.suggestions[0].savedTaskID = "imported-task"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try MeetingRepository(root: root); try repository.save(record)
        let restored = try repository.load()[0]
        XCTAssertEqual(restored.analysisProgress?.completedBatchIDs, [id])
        XCTAssertEqual(restored.processingPhase, .analysis)
        XCTAssertEqual(MeetingAnalysisCheckpoint.applying(part, batchID: id, topicsOnly: false, to: restored), restored)
        var renamed = record; renamed.speakerNames["A"] = "Reviewer"
        XCTAssertFalse(MeetingAnalysisCheckpoint.configuration(meeting: renamed, knownTags: ["T1A"], connection: connection, topicsOnly: false) == configuration)
        XCTAssertFalse(MeetingAnalysisCheckpoint.configuration(meeting: record, knownTags: ["T1A"], connection: .init(baseURL: connection.baseURL, model: "other"), topicsOnly: false) == configuration)
        let reset = MeetingAnalysisCheckpoint.starting(restored, configuration: "changed", restart: false)
        XCTAssertEqual(reset.suggestions, restored.suggestions); XCTAssertTrue(reset.analysisProgress!.completedBatchIDs.isEmpty)
    }
    func testRetryPolicyDoesNotRetryInvalidModelsOrCancellation() {
        XCTAssertTrue(MeetingRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(MeetingRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertFalse(MeetingRetryPolicy.shouldRetry(URLError(.cancelled)))
        for status in [400, 401, 403, 404, 413] { XCTAssertFalse(MeetingRetryPolicy.shouldRetry(MeetingGatewayFailure(stage: .analysis, status: status, model: "fixture", path: "/chat"))) }
        for status in [408, 429, 500, 502, 503, 504] { XCTAssertTrue(MeetingRetryPolicy.shouldRetry(MeetingGatewayFailure(stage: .analysis, status: status, model: "fixture", path: "/chat"))) }
        XCTAssertEqual(MeetingRetryPolicy.delay(after: 1), 1); XCTAssertEqual(MeetingRetryPolicy.delay(after: 2), 2)
        XCTAssertEqual(MeetingRetryPolicy.delay(after: 1, retryAfter: 7), 7)
    }
}
