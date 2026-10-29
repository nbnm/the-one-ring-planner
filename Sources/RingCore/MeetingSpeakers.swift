import Foundation
import CryptoKit

public struct MeetingSpeakerAlias: Codable, Equatable, Identifiable, Sendable {
    public static let myselfID = "myself"
    public let id: String
    public var name: String
    public var isMe: Bool { id == Self.myselfID }
    public var displayName: String { isMe && name != "Me" ? "\(name) · Me" : name }
    public init(id: String = UUID().uuidString.lowercased(), name: String) { self.id = id; self.name = name }
}
public enum MeetingSpeakerColor: String, Sendable { case pink, blue, green, orange, purple, teal, neutral }
public enum MeetingTaskOwnership: Int, CaseIterable, Sendable { case mine, unassigned, others }
public struct MeetingSpeakerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let speakerIDs: [String]
    public let isMe: Bool
}

extension MeetingRecording {
    private static func legacyAliasID(_ name: String) -> String {
        "named-" + SHA256.hash(data: Data(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var availableSpeakerIDs: [String] {
        var seen = Set<String>()
        return MeetingNavigation.ordered(segments).map(\.speakerID).filter { seen.insert($0).inserted }
    }
    public var availableSpeakerAliases: [MeetingSpeakerAlias] {
        var result = speakerAliases ?? []
        if !result.contains(where: \.isMe) { result.insert(.init(id: MeetingSpeakerAlias.myselfID, name: "Me"), at: 0) }
        var ids = Set(result.map(\.id))
        for (speaker, name) in speakerNames.sorted(by: { $0.key < $1.key }) where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && speakerAliasAssignments?[speaker] == nil {
            let id = Self.legacyAliasID(name)
            // Explicit assignments supersede the legacy display-name dictionary.
            if ids.insert(id).inserted { result.append(.init(id: id, name: name)) }
        }
        return result.sorted { $0.isMe != $1.isMe ? $0.isMe : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func speakerAlias(for speaker: String) -> MeetingSpeakerAlias? {
        if let id = speakerAliasAssignments?[speaker] {
            if let alias = speakerAliases?.first(where: { $0.id == id }) { return alias }
            return id == MeetingSpeakerAlias.myselfID ? .init(id: id, name: "Me") : nil
        }
        guard let name = speakerNames[speaker], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(id: Self.legacyAliasID(name), name: name)
    }
    public func isMySpeaker(_ speaker: String) -> Bool { speakerAlias(for: speaker)?.isMe == true }
    public func speakerColor(_ speaker: String) -> MeetingSpeakerColor {
        guard let alias = speakerAlias(for: speaker) else { return .neutral }
        if alias.isMe { return .pink }
        let colors: [MeetingSpeakerColor] = [.blue, .green, .orange, .purple, .teal]
        return colors[Int(Array(SHA256.hash(data: Data(alias.id.utf8)))[0]) % colors.count]
    }
    private mutating func materializeSpeakerAliases() {
        let aliases = availableSpeakerAliases
        var assignments = speakerAliasAssignments ?? [:]
        for speaker in speakerNames.keys where assignments[speaker] == nil {
            assignments[speaker] = speakerNames[speaker].map(Self.legacyAliasID)
        }
        speakerAliases = aliases; speakerAliasAssignments = assignments
    }
    @discardableResult public mutating func addSpeakerAlias(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw MeetingError.validation("Use an alias of 1–100 characters.") }
        if let existing = availableSpeakerAliases.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        materializeSpeakerAliases()
        let alias = MeetingSpeakerAlias(name: name); speakerAliases?.append(alias); return alias.id
    }
    public mutating func renameSpeakerAlias(_ id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw MeetingError.validation("Use an alias of 1–100 characters.") }
        guard !availableSpeakerAliases.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw MeetingError.validation("That alias already exists.") }
        materializeSpeakerAliases()
        guard let index = speakerAliases?.firstIndex(where: { $0.id == id }) else { return }
        speakerAliases?[index].name = name
        for (speaker, assignment) in speakerAliasAssignments ?? [:] where assignment == id { speakerNames[speaker] = name }
    }
    public mutating func assignSpeaker(_ speaker: String, aliasID: String?) {
        guard availableSpeakerIDs.contains(speaker) else { return }
        materializeSpeakerAliases()
        let alias = availableSpeakerAliases.first { $0.id == aliasID }
        // Empty is an explicit clear, so a legacy name cannot restore an assignment.
        speakerAliasAssignments?[speaker] = alias?.id ?? ""
        speakerNames[speaker] = alias?.name
    }
    public mutating func resetSpeakerAssignments() {
        // A new transcription can reuse A/B labels for different people.
        // Keep the alias library, but require explicit reassignment to new voices.
        speakerAliases = availableSpeakerAliases
        speakerAliasAssignments = [:]; speakerNames = [:]
    }
    public var speakerGroups: [MeetingSpeakerGroup] {
        var order: [String] = [], grouped: [String: [String]] = [:]
        for speaker in availableSpeakerIDs {
            let key = speakerAlias(for: speaker).map { "alias:" + $0.id } ?? "speaker:" + speaker
            if grouped[key] == nil { order.append(key) }; grouped[key, default: []].append(speaker)
        }
        let values = order.map { key -> MeetingSpeakerGroup in
            let speakers = grouped[key]!, first = speakers[0]
            return .init(id: key, name: speakerName(first), speakerIDs: speakers, isMe: isMySpeaker(first))
        }
        return values.filter(\.isMe) + values.filter { !$0.isMe }
    }
    public func ownership(of task: MeetingTaskSuggestion) -> MeetingTaskOwnership {
        guard let speaker = task.speakerID, !speaker.isEmpty else { return .unassigned }
        if isMySpeaker(speaker) { return .mine }
        return speaker.hasSuffix(":unassigned") && speakerAlias(for: speaker) == nil ? .unassigned : .others
    }
    public var orderedSuggestions: [MeetingTaskSuggestion] {
        MeetingTaskOwnership.allCases.flatMap { ownership in suggestions.filter { self.ownership(of: $0) == ownership } }
    }
    public func ownerGroup(for task: MeetingTaskSuggestion) -> String {
        guard let speaker = task.speakerID else { return "" }
        return speakerGroups.first { $0.speakerIDs.contains(speaker) }?.id ?? ""
    }
    public mutating func assignTaskOwner(_ taskID: String, groupID: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == taskID }), suggestions[index].savedTaskID == nil else { return }
        let speakers = speakerGroups.first { $0.id == groupID }?.speakerIDs ?? []
        if let existing = suggestions[index].speakerID, speakers.contains(existing) { return }
        suggestions[index].speakerID = speakers.first
    }
    public func matchingTranscript(query: String, groupID: String) -> [MeetingSegment] {
        let speakers = Set(speakerGroups.first { $0.id == groupID }?.speakerIDs ?? [])
        return MeetingNavigation.matching(segments, query: query).filter { groupID.isEmpty || speakers.contains($0.speakerID) }
    }
}
