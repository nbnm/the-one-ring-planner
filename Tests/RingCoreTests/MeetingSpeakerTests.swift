import Foundation
import RingCore

struct MeetingSpeakerTests {
    private var record: MeetingRecording {
        var value = MeetingRecording(title: "Speaker fixture", language: .automatic, source: .callAndMicrophone, now: Date(timeIntervalSince1970: 1700000000))
        value.state = .ready; value.duration = 400
        value.segments = [.init(id: "a", start: 0, end: 8, speakerID: "stt-0-100:A", text: "My first passage"),
                          .init(id: "b", start: 8, end: 18, speakerID: "stt-0-100:B", text: "Their passage"),
                          .init(id: "c", start: 300, end: 310, speakerID: "stt-100-200:C", text: "My later passage")]
        value.suggestions = [.init(title: "Theirs", speakerID: "stt-0-100:B", evidenceIDs: ["b"]),
                             .init(title: "No owner", evidenceIDs: ["b"]),
                             .init(title: "Mine later", speakerID: "stt-100-200:C", evidenceIDs: ["c"]),
                             .init(title: "Mine first", speakerID: "stt-0-100:A", evidenceIDs: ["a"])]
        return value
    }
    func testSharedAliasesMeColorAndGroupedFiltering() throws {
        var value = record
        XCTAssertEqual(value.availableSpeakerAliases.map(\.id), [MeetingSpeakerAlias.myselfID])
        XCTAssertFalse(value.isMySpeaker(value.segments[0].speakerID))
        value.assignSpeaker(value.segments[0].speakerID, aliasID: MeetingSpeakerAlias.myselfID)
        value.assignSpeaker(value.segments[2].speakerID, aliasID: MeetingSpeakerAlias.myselfID)
        let alex = try value.addSpeakerAlias(name: "Alex")
        value.assignSpeaker(value.segments[1].speakerID, aliasID: alex)
        XCTAssertEqual(value.speakerColor(value.segments[0].speakerID), .pink)
        XCTAssertEqual(value.speakerColor(value.segments[2].speakerID), .pink)
        XCTAssertFalse(value.speakerColor(value.segments[1].speakerID) == .pink)
        XCTAssertEqual(value.speakerGroups.count, 2); XCTAssertTrue(value.speakerGroups[0].isMe)
        XCTAssertEqual(value.matchingTranscript(query: "", groupID: value.speakerGroups[0].id).map(\.id), ["a", "c"])
        XCTAssertEqual(value.matchingTranscript(query: "later", groupID: value.speakerGroups[0].id).map(\.id), ["c"])
        try value.renameSpeakerAlias(MeetingSpeakerAlias.myselfID, name: "Oleg")
        XCTAssertEqual(value.speakerName(value.segments[0].speakerID), "Oleg · Me")
        XCTAssertEqual(value.speakerColor(value.segments[2].speakerID), .pink)
        XCTAssertEqual(try value.addSpeakerAlias(name: " alex "), alex)
        XCTAssertThrowsError(try value.renameSpeakerAlias(alex, name: "Oleg"))
        value.assignSpeaker(value.segments[0].speakerID, aliasID: alex)
        XCTAssertFalse(value.isMySpeaker(value.segments[0].speakerID)); XCTAssertTrue(value.isMySpeaker(value.segments[2].speakerID))
        value.assignSpeaker(value.segments[2].speakerID, aliasID: nil)
        XCTAssertEqual(value.speakerColor(value.segments[2].speakerID), .neutral)
        value.resetSpeakerAssignments()
        XCTAssertTrue(value.availableSpeakerAliases.contains { $0.id == alex })
        XCTAssertTrue(value.availableSpeakerIDs.allSatisfy { value.speakerAlias(for: $0) == nil })
    }
    func testTaskOrderChangesWithAliasesAndOwnerEditsWithoutChangingEvidence() throws {
        var value = record
        let originalEvidence = value.suggestions.map(\.evidenceIDs)
        value.assignSpeaker(value.segments[0].speakerID, aliasID: MeetingSpeakerAlias.myselfID)
        value.assignSpeaker(value.segments[2].speakerID, aliasID: MeetingSpeakerAlias.myselfID)
        XCTAssertEqual(value.orderedSuggestions.map(\.title), ["Mine later", "Mine first", "No owner", "Theirs"])
        let me = value.speakerGroups.first { $0.isMe }!
        let mine = value.suggestions[2].id
        value.assignTaskOwner(mine, groupID: me.id)
        XCTAssertEqual(value.suggestions[2].speakerID, value.segments[2].speakerID) // preserve this chunk's evidence owner
        value.assignTaskOwner(value.suggestions[0].id, groupID: me.id)
        XCTAssertEqual(value.orderedSuggestions.map(\.title), ["Theirs", "Mine later", "Mine first", "No owner"])
        value.assignTaskOwner(mine, groupID: "")
        XCTAssertEqual(value.ownership(of: value.suggestions[2]), .unassigned)
        XCTAssertEqual(value.suggestions.map(\.evidenceIDs), originalEvidence)
        let receipt = try MeetingTaskImport(meeting: value, settings: PlanningSettings(), knownTags: [])
        XCTAssertTrue(receipt.tasks[0].notes.contains("Owner: Me"))
        value.suggestions[0].savedTaskID = "saved"
        value.assignTaskOwner(value.suggestions[0].id, groupID: "")
        XCTAssertEqual(value.ownership(of: value.suggestions[0]), .mine)
    }
    func testLegacyNamesAliasEditsAndSelfSelectionSurviveRepositoryRestart() throws {
        var value = record
        value.speakerNames[value.segments[0].speakerID] = "Oleg"
        value.speakerNames[value.segments[2].speakerID] = "Oleg"
        let original = value
        let legacy = value.speakerAlias(for: value.segments[0].speakerID)!
        XCTAssertEqual(value.speakerGroups[0].speakerIDs.count, 2)
        XCTAssertFalse(legacy.isMe) // names never guess the user's identity
        try value.renameSpeakerAlias(legacy.id, name: "Oleg M.")
        XCTAssertEqual(value.speakerName(value.segments[2].speakerID), "Oleg M.")
        value.assignSpeaker(value.segments[0].speakerID, aliasID: MeetingSpeakerAlias.myselfID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try MeetingRepository(root: root)
        try repository.save(value)
        let loaded = try repository.load()[0]
        XCTAssertEqual(loaded, value); XCTAssertEqual(loaded.speakerColor(value.segments[0].speakerID), .pink)
        XCTAssertEqual(loaded.segments, original.segments); XCTAssertEqual(loaded.suggestions, original.suggestions)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "speakerAliases"); json.removeValue(forKey: "speakerAliasAssignments")
        let old = try JSONDecoder().decode(MeetingRecording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.speakerName(value.segments[0].speakerID), "Oleg")
        XCTAssertFalse(old.isMySpeaker(value.segments[0].speakerID))
    }
}
