import Foundation

public enum TaskState: String, Codable, CaseIterable, Sendable { case inbox, ready, inProgress, waiting, done, archived }
public enum Quadrant: Int, Codable, CaseIterable, Identifiable {
    case doFirst = 1, schedule, delegate, reconsider
    public var id: Int { rawValue }
    public var title: String { ["Do first", "Make time", "Delegate / batch", "Reconsider"][rawValue - 1] }
    public var subtitle: String { ["Important & urgent", "Important, not urgent", "Urgent, not important", "Neither important nor urgent"][rawValue - 1] }
    public var symbol: String { ["bolt", "leaf", "arrow.up.right", "moon"][rawValue - 1] }
}

public struct PlannerTask: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 3
    public var id: String
    public var title: String
    public var context: String
    public var notes: String
    public var tags: [String]
    public var sourceCaptureID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var state: TaskState
    public var importance: Bool?
    public var urgency: Bool?
    public var remainingMinutes: Int?
    public var minimumBlockMinutes: Int
    public var allowsSplitting: Bool
    public var deadline: Date?
    public var earliestStart: Date?
    public var dependencies: [String]
    public var resumeNote: String
    public var completedAt: Date? = nil
    public var completionID: String? = nil
    public var quadrant: Quadrant? {
        guard let importance, let urgency else { return nil }
        return importance ? (urgency ? .doFirst : .schedule) : (urgency ? .delegate : .reconsider)
    }
    public var isEligible: Bool { (state == .ready || state == .inProgress) && quadrant != nil && (remainingMinutes ?? 0) > 0 }
    public init(id: String = UUID().uuidString.lowercased(), title: String, context: String = "", notes: String = "", tags: [String] = [], state: TaskState = .inbox, importance: Bool? = nil, urgency: Bool? = nil, remainingMinutes: Int? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.context = context; self.state = state
        self.notes = notes; self.tags = TaskTags.normalize(tags)
        self.createdAt = now; self.updatedAt = now; self.revision = 1
        self.importance = importance; self.urgency = urgency; self.remainingMinutes = remainingMinutes
        self.minimumBlockMinutes = 25; self.allowsSplitting = true; self.dependencies = []; self.resumeNote = ""
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, context, notes, tags, sourceCaptureID, createdAt, updatedAt, revision, state
        case importance, urgency, remainingMinutes, minimumBlockMinutes, allowsSplitting, deadline, earliestStart, dependencies, resumeNote, completedAt, completionID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = max(3, try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        context = try c.decode(String.self, forKey: .context)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = TaskTags.normalize(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
        sourceCaptureID = try c.decodeIfPresent(String.self, forKey: .sourceCaptureID)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revision = try c.decode(Int.self, forKey: .revision); state = try c.decode(TaskState.self, forKey: .state)
        importance = try c.decodeIfPresent(Bool.self, forKey: .importance); urgency = try c.decodeIfPresent(Bool.self, forKey: .urgency)
        remainingMinutes = try c.decodeIfPresent(Int.self, forKey: .remainingMinutes)
        minimumBlockMinutes = try c.decode(Int.self, forKey: .minimumBlockMinutes)
        allowsSplitting = try c.decode(Bool.self, forKey: .allowsSplitting)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline); earliestStart = try c.decodeIfPresent(Date.self, forKey: .earliestStart)
        dependencies = try c.decode([String].self, forKey: .dependencies); resumeNote = try c.decode(String.self, forKey: .resumeNote)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completionID = try c.decodeIfPresent(String.self, forKey: .completionID)
    }
}

public struct Capture: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var text: String
    public var createdAt: Date
    public var timeZone: String
    public var taskIDs: [String]
    public init(text: String, timeZone: String, taskID: String, now: Date = Date()) {
        self.init(text: text, timeZone: timeZone, taskIDs: [taskID], now: now)
    }
    public init(text: String, timeZone: String, taskIDs: [String], now: Date = Date()) {
        id = UUID().uuidString.lowercased(); self.text = text; createdAt = now; self.timeZone = timeZone; self.taskIDs = taskIDs
    }
}

public enum RoutineKind: String, Codable, CaseIterable {
    case general, guitar, movement, review
    public var title: String {
        switch self { case .general: return "A little gold"; case .guitar: return "Guitar"; case .movement: return "Movement"; case .review: return "Daily review" }
    }
    public var symbol: String {
        switch self { case .general: return "sparkles"; case .guitar: return "guitars"; case .movement: return "figure.walk"; case .review: return "book.closed" }
    }
}
public struct Routine: Codable, Identifiable, Equatable {
    public var schemaVersion = 2
    public var id: String
    public var title: String
    public var kind: RoutineKind
    public var minutes: Int
    public var startMinute: Int
    public var endMinute: Int
    public var protected: Bool
    public var important: Bool
    public var urgent: Bool
    public var enabled: Bool
    public var weekdays: [RoutineWeekday]
    public init(id: String = UUID().uuidString.lowercased(), title: String, kind: RoutineKind = .general, minutes: Int, startMinute: Int, endMinute: Int, protected: Bool = false, important: Bool = true, urgent: Bool = false, enabled: Bool = false, weekdays: [RoutineWeekday] = RoutineWeekday.allCases) {
        self.id = id; self.title = title; self.kind = kind; self.minutes = minutes; self.startMinute = startMinute
        self.endMinute = endMinute; self.protected = protected; self.important = important; self.urgent = urgent; self.enabled = enabled
        self.weekdays = RoutineWeekday.allCases.filter { weekdays.contains($0) }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, title, kind, minutes, startMinute, endMinute, protected, important, urgent, enabled, weekdays }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = max(2, try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(RoutineKind.self, forKey: .kind); minutes = try c.decode(Int.self, forKey: .minutes)
        startMinute = try c.decode(Int.self, forKey: .startMinute); endMinute = try c.decode(Int.self, forKey: .endMinute)
        protected = try c.decode(Bool.self, forKey: .protected); important = try c.decode(Bool.self, forKey: .important)
        urgent = try c.decode(Bool.self, forKey: .urgent); enabled = try c.decode(Bool.self, forKey: .enabled)
        let days = try c.decodeIfPresent([RoutineWeekday].self, forKey: .weekdays) ?? RoutineWeekday.allCases
        weekdays = RoutineWeekday.allCases.filter { days.contains($0) }
    }
    public static let defaults: [Routine] = [
        .init(id: "movement", title: "A little movement", kind: .movement, minutes: 20, startMinute: 660, endMinute: 900),
        .init(id: "guitar", title: "Guitar, just for you", kind: .guitar, minutes: 10, startMinute: 840, endMinute: 990),
        .init(id: "evening-review", title: "Close the day", kind: .review, minutes: 10, startMinute: 990, endMinute: 1020, protected: true)
    ]
}

public struct PlanningSettings: Codable, Equatable {
    public var schemaVersion = 1
    public var timeZone = "America/Toronto"
    public var workStart = 540
    public var workEnd = 1020
    public var lunchStart = 720
    public var lunchMinutes = 60
    public var reservePercent = 20
    public var focusMinutes = 50
    public var minimumFocusMinutes = 25
    public var relatedTransition = 5
    public var projectTransition = 10
    public var meetingPreparation = 5
    public var meetingRecovery = 10
    public var adminBudget = 30
    public var freezeMinutes = 15
    public var speechLocale = "en-US"
    public init() {}
    public var isValid: Bool {
        TimeZone(identifier: timeZone) != nil && workStart >= 0 && workEnd <= 1440 && workEnd > workStart && lunchMinutes >= 0 && lunchStart >= workStart && lunchStart + lunchMinutes <= workEnd && reservePercent >= 0 && reservePercent <= 50 && focusMinutes >= 15 && minimumFocusMinutes >= 5 && minimumFocusMinutes <= focusMinutes
    }
}

public enum BlockKind: String, Codable { case focus, meeting, transition, routine, lunch }
public enum BlockState: String, Codable { case planned, running, completed, interrupted, skipped }
public struct PlanBlock: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var context: String
    public var kind: BlockKind
    public var start: Date
    public var end: Date
    public var taskID: String?
    public var routineID: String?
    public var pinned: Bool
    public var protected: Bool
    public var state: BlockState
    public var actualStartedAt: Date?
    public var actualMinutes: Int?
    /// The original publication owns this block even after a Google move to another date.
    public var calendarOwnerDay: String? = nil
    public var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    public init(id: String, title: String, context: String = "", kind: BlockKind, start: Date, end: Date, taskID: String? = nil, routineID: String? = nil, pinned: Bool = false, protected: Bool = false, state: BlockState = .planned) {
        self.id = id; self.title = title; self.context = context; self.kind = kind; self.start = start; self.end = end
        self.taskID = taskID; self.routineID = routineID; self.pinned = pinned; self.protected = protected; self.state = state
    }
}
public struct Unscheduled: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var minutes: Int
    public var reason: String
    public init(id: String, title: String, minutes: Int, reason: String) { self.id = id; self.title = title; self.minutes = minutes; self.reason = reason }
}
public enum PlanStatus: String, Codable { case draft, local }
public struct DayPlan: Codable, Identifiable, Equatable {
    public var schemaVersion = 2
    public var id: String
    public var revision: Int
    public var status: PlanStatus
    public var outcomeIDs: [String]
    /// nil uses all eligible tasks; an empty list deliberately plans no tasks.
    public var selectedTaskIDs: [String]? = nil
    public var publication: CalendarPublication? = nil
    public var blocks: [PlanBlock]
    public var unscheduled: [Unscheduled]
    public var warnings: [String]
    public var workMinutes: Int
    public var fixedMinutes: Int
    public var reserveMinutes: Int
    public var createdAt: Date
    public var previousBlocks: [PlanBlock]?
    public var plannedMinutes: Int { blocks.filter { $0.kind == .focus || $0.kind == .routine }.reduce(0) { $0 + $1.minutes } }
    public var completedMinutes: Int { blocks.filter { $0.state == .completed }.reduce(0) { $0 + ($1.actualMinutes ?? $1.minutes) } }
    public var freeMinutes: Int { max(0, workMinutes - blocks.reduce(0) { $0 + $1.minutes }) }
}

public enum PlannerDate {
    public static func calendar(_ settings: PlanningSettings) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: settings.timeZone) ?? .current; return c
    }
    public static func key(_ date: Date, settings: PlanningSettings) -> String {
        let f = DateFormatter(); f.calendar = calendar(settings); f.timeZone = f.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func at(_ minute: Int, on day: Date, settings: PlanningSettings) -> Date {
        let c = calendar(settings)
        if minute == 1440 { return c.date(byAdding: .day, value: 1, to: c.startOfDay(for: day)) ?? day }
        return c.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }
}
