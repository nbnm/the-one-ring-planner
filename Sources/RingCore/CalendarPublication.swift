import Foundation
import CryptoKit

public struct PublicationDestination: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let accountID: String
    public let primary: Bool
    public init(id: String, title: String, accountID: String, primary: Bool = false) { self.id = id; self.title = title; self.accountID = accountID; self.primary = primary }
}

public struct CalendarPlanEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let blockID: String
    public let taskID: String?
    public let routineID: String?
    public let title: String
    public let context: String
    public let start: Date
    public let end: Date
    public let timeZone: String
    public var kind: BlockKind { routineID == nil ? .focus : .routine }
    public var category: PlannerCalendarCategory { routineID == nil ? .task : .routine }
    public var googleColorID: String { category.googleColorID }
    public var hasValidSource: Bool {
        (taskID != nil) != (routineID != nil) && !(taskID ?? routineID ?? "").isEmpty
    }
    public static func identifier(workspaceID: String, day: String, blockID: String) -> String {
        SHA256.hash(data: Data("\(workspaceID)|\(day)|\(blockID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func metadata(workspaceID: String, day: String) -> [String: String] {
        var properties = ["ringWorkspace": workspaceID, "ringDay": day, "ringBlock": blockID, "ringVersion": "1"]
        properties["ringTask"] = taskID; properties["ringRoutine"] = routineID
        return properties
    }
    public static func isOwned(eventID: String, metadata: [String: String], workspaceID: String?) -> Bool {
        guard let workspaceID, metadata["ringWorkspace"] == workspaceID, metadata["ringVersion"] == "1",
              let day = metadata["ringDay"], let block = metadata["ringBlock"],
              (metadata["ringTask"] != nil) != (metadata["ringRoutine"] != nil),
              !(metadata["ringTask"] ?? metadata["ringRoutine"] ?? "").isEmpty else { return false }
        return eventID == identifier(workspaceID: workspaceID, day: day, blockID: block)
    }
    public static func events(plan: DayPlan, workspaceID: String, timeZone: String) -> [Self] {
        plan.blocks.filter {
            ($0.calendarOwnerDay == nil || $0.calendarOwnerDay == plan.id) &&
            (($0.kind == .focus && $0.taskID != nil) || ($0.kind == .routine && $0.routineID != nil)) && $0.state != .interrupted && $0.state != .skipped
        }.map {
            Self(id: identifier(workspaceID: workspaceID, day: plan.id, blockID: $0.id), blockID: $0.id,
                 taskID: $0.kind == .focus ? $0.taskID : nil, routineID: $0.kind == .routine ? $0.routineID : nil,
                 title: $0.title, context: $0.context, start: $0.start, end: $0.end, timeZone: timeZone)
        }.sorted { $0.id < $1.id }
    }
    public func rescheduled(start: Date, end: Date) -> Self {
        Self(id: id, blockID: blockID, taskID: taskID, routineID: routineID, title: title, context: context, start: start, end: end, timeZone: timeZone)
    }
}

public struct CalendarPublication: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, published, needsConfirmation }
    public let id: String
    public let workspaceID: String
    public let day: String
    public let destination: PublicationDestination
    public var confirmedBlockIDs: [String]?
    public var observedPlanEvents: [CalendarPlanEvent]?
    public var desired: [CalendarPlanEvent]
    /// Last accepted Google times, used to distinguish a remote move from an unsent local edit.
    public var lastPublishedEvents: [CalendarPlanEvent]? = nil
    public var missingEventIDs: [String]? = nil
    /// Includes every event that an earlier attempt might have created, even after an unknown response.
    public var known: [CalendarPlanEvent]
    public var state: State
    public var lastError: String?
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var publishedAt: Date?
    public init(plan: DayPlan, workspaceID: String, destination: PublicationDestination, timeZone: String, confirmedBlockIDs: [String]? = nil, keepingExistingEvents: Bool = false) {
        id = UUID().uuidString.lowercased(); self.workspaceID = plan.publication?.workspaceID ?? workspaceID
        day = plan.id; self.destination = plan.publication?.destination ?? destination
        let allEvents = CalendarPlanEvent.events(plan: plan, workspaceID: self.workspaceID, timeZone: timeZone)
        let selected = allEvents.filter { confirmedBlockIDs?.contains($0.blockID) ?? true }
        if keepingExistingEvents {
            let observedIDs = Array(Set((plan.publication?.desired.map(\.blockID) ?? []) + (confirmedBlockIDs ?? []))).sorted()
            self.confirmedBlockIDs = observedIDs
            observedPlanEvents = allEvents.filter { observedIDs.contains($0.blockID) }
            var carried = Dictionary(uniqueKeysWithValues: (plan.publication?.desired ?? []).map { ($0.id, $0) })
            for event in selected { carried[event.id] = event }
            desired = carried.values.sorted { $0.id < $1.id }
        } else {
            self.confirmedBlockIDs = confirmedBlockIDs.map { Array(Set($0)).sorted() }
            observedPlanEvents = nil; desired = selected
        }
        var entries = Dictionary(uniqueKeysWithValues: (plan.publication?.known ?? []).map { ($0.id, $0) })
        for event in (plan.publication?.desired ?? []) + desired { entries[event.id] = event }
        known = entries.values.sorted { $0.id < $1.id }
        state = .pending; attempts = 0
        lastPublishedEvents = plan.publication?.lastPublishedEvents ?? (plan.publication?.state == .published || plan.publication?.state == .needsConfirmation ? plan.publication?.desired : nil)
    }
    public func matches(_ plan: DayPlan, timeZone: String) -> Bool {
        (observedPlanEvents ?? desired) == CalendarPlanEvent.events(plan: plan, workspaceID: workspaceID, timeZone: timeZone).filter { confirmedBlockIDs?.contains($0.blockID) ?? true }
    }
    public func hasUnconfirmedEvents(in plan: DayPlan, timeZone: String) -> Bool {
        CalendarPlanEvent.events(plan: plan, workspaceID: workspaceID, timeZone: timeZone).contains { !desired.contains($0) }
    }
    public func invalidatingChanges(in plan: DayPlan, timeZone: String) -> Self {
        var result = self
        if !matches(plan, timeZone: timeZone) { result.state = .needsConfirmation; result.lastError = nil; result.nextAttemptAt = nil }
        return result
    }
}

public enum CalendarPublicationError: LocalizedError {
    case destination, account, foreignEvent, conflict, removedEvent, invalidPlan
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose a Google calendar you own in Settings → Google Calendar."
        case .account: return "This plan belongs to a different Google account. Switch back to that account before publishing."
        case .foreignEvent: return "A calendar event does not belong to this planner. It was left unchanged."
        case .conflict: return "A calendar event changed during publishing. Retry to check its latest version."
        case .removedEvent: return "A planned event was deleted in Google Calendar. Restore it in Google's Trash before retrying this plan."
        case .invalidPlan: return "This plan has invalid task times or identifiers and could not be published."
        }
    }
}
