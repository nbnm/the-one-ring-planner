import Foundation
import RingCore

struct MeetingTranscriptVersionTests {
    private let date = Date(timeIntervalSince1970: 1700000000)
    private var connection: LiteLLMConnection { .init(baseURL: "https://gateway.example/v1", model: "text") }
    private var original: MeetingRecording {
        var record = MeetingRecording(title: "Version fixture", language: .english, source: .systemAndMicrophone, now: date)
        record.state = .ready; record.duration = 180
        record.segments = [.init(id: "old", start: 0, end: 10, speakerID: "old:A", text: "Original evidence")]
        record.assignSpeaker("old:A", aliasID: MeetingSpeakerAlias.myselfID)
        record.summaries = ["Original summary"]
        record.suggestions = [.init(title: "Already reviewed", speakerID: "old:A", evidenceIDs: ["old"])]
        record.suggestions[0].savedTaskID = "existing-inbox-task"; record.suggestions[0].included = false
        record.audioConfiguration = "https://gateway.example/v1|whisper-1|false|english"; record.completedAudioParts = ["stt-0-2880000"]
        return record
    }
    func testFreshAttemptPreservesActiveTranscriptAndImportedEvidence() throws {
        let source = original
        var record = try MeetingTranscriptVersions.begin(source, model: "whisper-1", language: .english, speakerLabels: true, connection: connection, now: date)
        let id = record.retranscription!.id
        XCTAssertEqual(record.segments, source.segments); XCTAssertEqual(record.suggestions, source.suggestions)
        let working = try MeetingTranscriptVersions.working(record, id: id)
        XCTAssertTrue(working.segments.isEmpty); XCTAssertTrue(working.completedAudioParts.isEmpty); XCTAssertEqual(working.importedTaskCount, 0)
        XCTAssertEqual(MeetingChunkPlanner.pending(totalFrames: 2880000, completed: working.completedAudioParts).count, 1)
        XCTAssertEqual(working.availableSpeakerAliases.first?.id, MeetingSpeakerAlias.myselfID)
        XCTAssertTrue(working.speakerAliasAssignments?.isEmpty == true)
        record = try MeetingTranscriptVersions.updating(record, id: id) {
            $0.segments = [.init(id: "new", start: 0, end: 8, speakerID: "new:A", text: "New evidence")]
            $0.completedAudioParts = ["stt-0-128000"]; $0.state = .interrupted; $0.lastError = "Cancelled"
        }
        XCTAssertEqual(record.state, .ready); XCTAssertEqual(record.segments, source.segments)
        XCTAssertEqual(try MeetingTranscriptVersions.working(record, id: id).completedAudioParts, ["stt-0-128000"])
        XCTAssertThrowsError(try MeetingTranscriptVersions.complete(record, id: id, now: date))
        XCTAssertThrowsError(try MeetingTranscriptVersions.updating(record, id: "missing") { $0.segments = [] })
    }
    func testModelSwitchActivationAndRepeatedRestoreKeepEvidenceAndReceipts() throws {
        let source = original
        var record = try MeetingTranscriptVersions.begin(source, model: "gpt-4o-transcribe-diarize", language: .automatic, speakerLabels: true, connection: connection, now: date)
        let newID = record.retranscription!.id
        record = try MeetingTranscriptVersions.updating(record, id: newID) {
            $0.segments = [.init(id: "new", start: 0, end: 9, speakerID: "new:A", text: "Revised evidence")]
            $0.summaries = ["Revised summary"]
            var proposal = source.suggestions[0]; proposal.savedTaskID = nil; proposal.included = true; proposal.evidenceIDs = ["new"]
            $0.suggestions = [proposal]; $0.state = .ready; $0.processingPhase = nil
            $0.audioConfiguration = "https://gateway.example/v1|gpt-4o-transcribe-diarize|true|automatic"
        }
        record = try MeetingTranscriptVersions.complete(record, id: newID, now: date)
        XCTAssertEqual(record.transcriptModel, "gpt-4o-transcribe-diarize"); XCTAssertEqual(record.segments[0].id, "new")
        XCTAssertEqual(record.suggestions[0].savedTaskID, "existing-inbox-task"); XCTAssertFalse(record.suggestions[0].included)
        XCTAssertEqual(record.transcriptVersions?.count, 1); XCTAssertEqual(record.transcriptVersions?[0].segments, source.segments)
        let oldID = record.transcriptVersions![0].id
        for _ in 0..<3 {
            record = try MeetingTranscriptVersions.restore(record, versionID: oldID, now: date)
            XCTAssertEqual(record.segments, source.segments); XCTAssertTrue(record.isMySpeaker("old:A"))
            XCTAssertEqual(record.suggestions[0].savedTaskID, "existing-inbox-task")
            record = try MeetingTranscriptVersions.restore(record, versionID: newID, now: date)
            XCTAssertEqual(record.segments[0].id, "new"); XCTAssertEqual(record.transcriptVersions?.count, 1)
        }
        XCTAssertEqual(record.id, source.id); XCTAssertEqual(record.createdAt, source.createdAt); XCTAssertEqual(record.duration, source.duration)
    }
    func testDraftRestartRetainsCheckpointsWithoutInterruptingActiveVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try MeetingRepository(root: root)
        var record = try MeetingTranscriptVersions.begin(original, model: "alternate", language: .russian, speakerLabels: true, connection: connection, now: date)
        let id = record.retranscription!.id
        record = try MeetingTranscriptVersions.updating(record, id: id) {
            $0.state = .analyzing; $0.processingPhase = .analysis
            $0.segments = [.init(id: "new", start: 0, end: 1, speakerID: "A", text: "Fixture")]
            $0.completedAudioParts = ["stt-0-2880000"]
            $0.analysisProgress = .init(configuration: "fixture")
            $0.analysisProgress?.completedBatchIDs = ["done"]
        }
        try repo.save(record)
        let restored = try repo.load()[0]
        XCTAssertEqual(restored.state, .ready); XCTAssertEqual(restored.segments, original.segments)
        XCTAssertEqual(restored.retranscription?.model, "alternate"); XCTAssertEqual(restored.retranscription?.textModel, "text")
        XCTAssertEqual(restored.retranscription?.content.state, .interrupted)
        let work = try MeetingTranscriptVersions.working(restored, id: id)
        XCTAssertEqual(work.processingPhase, .analysis); XCTAssertEqual(work.analysisProgress?.completedBatchIDs, ["done"])
        XCTAssertEqual(work.completedAudioParts, ["stt-0-2880000"])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for key in ["transcriptVersions", "activeTranscriptVersionID", "retranscription"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(MeetingRecording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.retranscription, nil); XCTAssertEqual(legacy.segments, original.segments)
    }
    func testStartingAnotherModelArchivesPartialWork() throws {
        var record = try MeetingTranscriptVersions.begin(original, model: "first-model", language: .english, speakerLabels: false, connection: connection, now: date)
        let id = record.retranscription!.id
        record = try MeetingTranscriptVersions.updating(record, id: id) { $0.segments = [.init(id: "partial", start: 0, end: 3, speakerID: "A", text: "Partial evidence")]; $0.state = .interrupted }
        record = try MeetingTranscriptVersions.begin(record, model: "second-model", language: .english, speakerLabels: false, connection: connection, now: date)
        XCTAssertEqual(record.segments, original.segments); XCTAssertEqual(record.retranscription?.model, "second-model")
        XCTAssertEqual(record.transcriptVersions?.first?.id, id); XCTAssertEqual(record.transcriptVersions?.first?.state, .interrupted)
        XCTAssertEqual(record.transcriptVersions?.first?.segments.first?.id, "partial")
        XCTAssertThrowsError(try MeetingTranscriptVersions.begin(record, model: " ", language: .english, speakerLabels: false, connection: connection))
    }
}
