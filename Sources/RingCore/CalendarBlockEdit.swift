import Foundation

/// A durable, single-occurrence operation. Its owner identity never changes when the date changes.
public struct CalendarBlockEdit: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, conflict, synced, cancelled }
    public let id: String
    public var publication: CalendarPublication
    public var baselineStart: Date
    public var baselineEnd: Date
    public var creating: Bool
    public var state: State = .pending
    public var attempts = 0
    public var lastError: String?
    public var nextAttemptAt: Date?
    public var syncedAt: Date?
    public var event: CalendarPlanEvent { publication.desired[0] }
    public var unresolved: Bool { state == .pending || state == .conflict }
    public init(publication: CalendarPublication, baselineStart: Date, baselineEnd: Date, creating: Bool) {
        precondition(publication.desired.count == 1)
        id = UUID().uuidString.lowercased(); self.publication = publication
        self.baselineStart = baselineStart; self.baselineEnd = baselineEnd; self.creating = creating
    }
    enum CodingKeys: String, CodingKey { case id, publication, baselineStart, baselineEnd, creating, state, attempts, lastError, nextAttemptAt, syncedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        publication = try c.decode(CalendarPublication.self, forKey: .publication)
        baselineStart = try c.decode(Date.self, forKey: .baselineStart); baselineEnd = try c.decode(Date.self, forKey: .baselineEnd)
        creating = try c.decode(Bool.self, forKey: .creating); state = try c.decode(State.self, forKey: .state)
        attempts = try c.decode(Int.self, forKey: .attempts); lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        nextAttemptAt = try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt); syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
        guard publication.desired.count == 1, baselineStart < baselineEnd,
              publication.known.allSatisfy({ $0.id == publication.desired[0].id }),
              CalendarBlockEditing.valid(start: publication.desired[0].start, end: publication.desired[0].end) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid calendar edit scope"))
        }
    }

}

public enum CalendarEditGeometry {
    public enum Edge { case move, start, end }
    public static func snap(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded() * 300) }
    /// Absolute time preserves elapsed duration across midnight and daylight saving changes.
    public static func proposal(start: Date, end: Date, target: Date, edge: Edge) -> DateInterval {
        let target = snap(target), minimum = 300.0, maximum = 86400.0
        switch edge {
        case .move: return DateInterval(start: target, end: target.addingTimeInterval(end.timeIntervalSince(start)))
        case .start: return DateInterval(start: max(end.addingTimeInterval(-maximum), min(target, end.addingTimeInterval(-minimum))), end: end)
        case .end: return DateInterval(start: start, end: min(start.addingTimeInterval(maximum), max(target, start.addingTimeInterval(minimum))))
        }
    }
}

public enum CalendarBlockEditing {
    public static func valid(start: Date, end: Date) -> Bool {
        start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite && end.timeIntervalSince(start) >= 300 && end.timeIntervalSince(start) <= 86400
    }
    /// Update the scope already confirmed for this owner, without confirming unrelated drafts.
    public static func recording(_ event: CalendarPlanEvent, in publication: CalendarPublication, acknowledged: Bool) -> CalendarPublication {
        var p = publication
        func replacing(_ values: [CalendarPlanEvent]) -> [CalendarPlanEvent] { (values.filter { $0.id != event.id } + [event]).sorted { $0.id < $1.id } }
        p.desired = replacing(p.desired); p.known = replacing(p.known)
        if p.observedPlanEvents != nil { p.observedPlanEvents = replacing(p.observedPlanEvents!) }
        if p.confirmedBlockIDs != nil { p.confirmedBlockIDs = Array(Set(p.confirmedBlockIDs! + [event.blockID])).sorted() }
        if acknowledged {
            p.lastPublishedEvents = replacing(p.lastPublishedEvents ?? [])
            p.missingEventIDs?.removeAll { $0 == event.id }
        }
        return p
    }
    public static func resizedTask(_ task: PlannerTask, from oldMinutes: Int, to newMinutes: Int, now: Date) -> PlannerTask {
        guard task.state == .ready || task.state == .waiting, oldMinutes != newMinutes else { return task }
        var t = task
        t.remainingMinutes = max(5, (t.remainingMinutes ?? oldMinutes) + newMinutes - oldMinutes)
        t.minimumBlockMinutes = min(t.minimumBlockMinutes, t.remainingMinutes!)
        t.updatedAt = now; t.revision += 1
        return t
    }
}
