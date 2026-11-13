import Foundation
import Combine
import CryptoKit

public enum CalendarAccess: Equatable, Sendable { case notDetermined, denied, restricted, writeOnly, full }

public struct CalendarDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let account: String
    public init(id: String, title: String, account: String) { self.id = id; self.title = title; self.account = account }
}

public enum PlannerCalendarCategory: Equatable, Sendable {
    case task, routine
    /// Google's event palette: Tomato for tasks, Basil for routine activities.
    public var googleColorID: String { self == .routine ? "10" : "11" }
}

public struct CalendarOccurrence: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceEventID: String
    public let calendarID: String
    public let title: String
    public let calendarTitle: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let busy: Bool
    public let managedByPlanner: Bool
    public let plannerCategory: PlannerCalendarCategory?
    public let plannerTaskID: String?
    public let plannerBlockID: String?
    public let plannerDay: String?
    public let plannerRoutineID: String?
    public let colorID: String?
    public init(id: String, calendarID: String, title: String, calendarTitle: String, start: Date, end: Date, allDay: Bool = false, busy: Bool = true, managedByPlanner: Bool = false, plannerCategory: PlannerCalendarCategory? = nil, colorID: String? = nil, plannerTaskID: String? = nil, plannerRoutineID: String? = nil, plannerBlockID: String? = nil, plannerDay: String? = nil) {
        let identity = SHA256.hash(data: Data("\(calendarID)|\(id)|\(start.timeIntervalSince1970)".utf8)).map { String(format: "%02x", $0) }.joined()
        self.id = "occurrence-\(identity)"; self.sourceEventID = id; self.calendarID = calendarID; self.title = title; self.calendarTitle = calendarTitle
        self.start = start; self.end = end; self.allDay = allDay; self.busy = busy
        self.plannerBlockID = managedByPlanner ? plannerBlockID : nil; self.plannerDay = managedByPlanner ? plannerDay : nil
        self.managedByPlanner = managedByPlanner
        self.plannerCategory = managedByPlanner ? plannerCategory : nil; self.colorID = colorID
        self.plannerTaskID = managedByPlanner ? plannerTaskID : nil; self.plannerRoutineID = managedByPlanner ? plannerRoutineID : nil
    }
    public func meeting(in window: DateInterval) -> PlanBlock? {
        let begin = max(start, window.start), finish = min(end, window.end)
        guard busy, begin < finish else { return nil }
        let digest = SHA256.hash(data: Data("\(calendarID)|\(id)|\(start.timeIntervalSince1970)".utf8)).map { String(format: "%02x", $0) }.joined()
        return PlanBlock(id: "calendar-\(digest)", title: title, context: calendarTitle + (allDay ? " · All day" : ""), kind: .meeting, start: begin, end: finish, pinned: true)
    }
}

public struct CalendarRead: Sendable {
    public let interval: DateInterval
    public let calendarIDs: Set<String>
    public let events: [CalendarOccurrence]
    public init(interval: DateInterval, calendarIDs: Set<String>, events: [CalendarOccurrence]) { self.interval = interval; self.calendarIDs = calendarIDs; self.events = events }
    public func meetings(day: Date, settings: PlanningSettings, fullDay: Bool = false) throws -> [PlanBlock] {
        let calendar = PlannerDate.calendar(settings)
        let start = calendar.startOfDay(for: day)
        guard interval.start == start, interval.end == calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CalendarConnectionError.changedDuringRead
        }
        let window = fullDay ? interval : DateInterval(start: PlannerDate.at(settings.workStart, on: day, settings: settings), end: PlannerDate.at(settings.workEnd, on: day, settings: settings))
        var seen = Set<String>()
        return events.filter { calendarIDs.contains($0.calendarID) && !$0.managedByPlanner }.compactMap { $0.meeting(in: window) }.filter { seen.insert($0.id).inserted }
    }
}

public enum CalendarConnectionError: LocalizedError {
    case accessRequired, selectCalendars, missingCalendars, changedDuringRead, invalidRange
    public var errorDescription: String? {
        switch self {
        case .accessRequired: return "Sign in with Google in Settings → Google Calendar to allow calendar read access."
        case .selectCalendars: return "Choose the calendars to include in Settings → Google Calendar."
        case .missingCalendars: return "A selected Google calendar is no longer available. Refresh and update your calendar selection."
        case .changedDuringRead: return "The calendar selection changed while loading. Refresh and try again."
        case .invalidRange: return "The calendar date range is invalid."
        }
    }
}

public protocol CalendarProviding: Sendable {
    func cancelAuthorization() async
    func disconnect() async throws
    func access() async -> CalendarAccess
    func requestAccess() async throws -> Bool
    func calendars(refresh: Bool) async throws -> [CalendarDescriptor]
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [CalendarOccurrence]
}

public extension CalendarProviding {
    func cancelAuthorization() async {}
    func disconnect() async throws {}
}

@MainActor public final class CalendarConnection: ObservableObject {
    /// Await downstream reconciliation before planning consumes a fresh calendar snapshot.
    public var onRefresh: ((CalendarRead) async -> Void)?
    @Published public private(set) var enabled: Bool
    @Published public private(set) var access = CalendarAccess.notDetermined
    @Published public private(set) var calendars: [CalendarDescriptor] = []
    @Published public private(set) var selectedIDs: Set<String>
    @Published public private(set) var events: [CalendarOccurrence] = []
    @Published public private(set) var loading = false
    @Published public private(set) var lastRead: Date?
    @Published public private(set) var message: String?
    @Published public private(set) var loadedInterval: DateInterval?
    private let provider: any CalendarProviding
    private let defaults: UserDefaults
    private var revision = UUID()
    private var configurationRevision = UUID()
    private var day: Date?
    private var settings: PlanningSettings?
    public init(provider: any CalendarProviding = GoogleCalendarProvider(), defaults: UserDefaults = .standard) {
        self.provider = provider; self.defaults = defaults
        enabled = defaults.bool(forKey: "googleCalendar.enabled")
        selectedIDs = Set(defaults.stringArray(forKey: "googleCalendar.selectedIDs") ?? [])
    }
    public var hasMissingCalendars: Bool { !selectedIDs.isSubset(of: Set(calendars.map(\.id))) }
    public var connected: Bool { enabled && access == .full && !selectedIDs.isEmpty && !hasMissingCalendars && lastRead != nil && message == nil }
    public var status: String {
        if loading { return "Checking calendars…" }
        if !enabled { return "Calendar not connected" }
        if access != .full { return "Google sign-in needed" }
        if calendars.isEmpty { return "No Google calendars available" }
        if selectedIDs.isEmpty { return "Choose calendars" }
        if hasMissingCalendars { return "Calendar unavailable" }
        if message != nil { return "Calendar needs attention" }
        return connected ? "\(selectedIDs.count) calendar\(selectedIDs.count == 1 ? "" : "s") connected" : "Refresh calendars"
    }
    public func connect(day: Date, settings: PlanningSettings) async {
        guard !loading else { return }
        loading = true; message = nil
        let id = revision
        do {
            guard try await provider.requestAccess() else { throw CalendarConnectionError.accessRequired }
            guard id == revision else { return }
            enabled = true; defaults.set(true, forKey: "googleCalendar.enabled")
            loading = false
            await refresh(day: day, settings: settings)
        } catch {
            guard id == revision else { return }
            access = await provider.access(); message = error.localizedDescription; loading = false
        }
    }
    public func select(_ id: String, included: Bool) {
        guard calendars.contains(where: { $0.id == id }) else { return }
        if included { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: "googleCalendar.selectedIDs")
        invalidate()
    }
    public func clearMissingCalendars() {
        selectedIDs.formIntersection(Set(calendars.map(\.id)))
        defaults.set(selectedIDs.sorted(), forKey: "googleCalendar.selectedIDs")
        invalidate()
    }
    public func suspendForRestoredWorkspace() { enabled = false; invalidate() }
    public func resumeAfterRestoreReview() { enabled = defaults.bool(forKey: "googleCalendar.enabled"); invalidate() }
    public func disconnect() async {
        enabled = false; defaults.set(false, forKey: "googleCalendar.enabled")
        selectedIDs = []; defaults.removeObject(forKey: "googleCalendar.selectedIDs")
        invalidate(); calendars = []; access = .notDetermined
        do { try await provider.disconnect() } catch { message = error.localizedDescription }
    }
    public func cancelCheck() async {
        invalidate()
        await provider.cancelAuthorization()
    }
    public var readRevision: UUID { configurationRevision }
    public func invalidate() {
        revision = UUID(); configurationRevision = UUID()
        events = []; lastRead = nil; loadedInterval = nil; message = nil; loading = false
    }
    @discardableResult public func refresh(day: Date, settings: PlanningSettings, refreshSources: Bool = true) async -> CalendarRead? {
        self.day = day; self.settings = settings
        let id = UUID(); revision = id
        let version = configurationRevision, selection = selectedIDs
        loading = true; message = nil; lastRead = nil; loadedInterval = nil; events = []
        guard enabled else { loading = false; return nil }
        do {
            let authorization = await provider.access()
            guard version == configurationRevision, enabled else { return nil }
            if revision == id { access = authorization }
            guard authorization == .full else { throw CalendarConnectionError.accessRequired }
            let choices = try await provider.calendars(refresh: refreshSources)
            guard version == configurationRevision, enabled else { return nil }
            if revision == id { calendars = choices }
            guard !selection.isEmpty else { if revision == id { loading = false }; return nil }
            guard selection.isSubset(of: Set(choices.map(\.id))) else { throw CalendarConnectionError.missingCalendars }
            let calendar = PlannerDate.calendar(settings)
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw CalendarConnectionError.invalidRange }
            let interval = DateInterval(start: start, end: end)
            let occurrences = try await provider.occurrences(in: interval, calendarIDs: selection)
            guard version == configurationRevision, enabled, selection == selectedIDs else { return nil }
            // Verify the provider's result as well as its query boundary.
            var seen = Set<String>()
            let filtered = occurrences.filter { selection.contains($0.calendarID) && $0.start < end && $0.end > start && $0.end > $0.start && seen.insert($0.id).inserted }
            let read = CalendarRead(interval: interval, calendarIDs: selection, events: filtered)
            if revision == id { events = filtered; loadedInterval = interval; lastRead = Date(); loading = false }
            await onRefresh?(read)
            guard version == configurationRevision, enabled, selection == selectedIDs else { return nil }
            return read
        } catch {
            guard revision == id else { return nil }
            let currentAccess = await provider.access()
            guard revision == id else { return nil }
            access = currentAccess
            events = []; loadedInterval = nil; lastRead = nil; message = error.localizedDescription; loading = false
            return nil
        }
    }
    public func refreshCurrentDay() async {
        guard enabled, let day, let settings else { return }
        await refresh(day: day, settings: settings, refreshSources: false)
    }
    /// A display range must never replace the single-day snapshot used by planning.
    public func readRange(_ interval: DateInterval) async throws -> CalendarRead {
        guard interval.duration > 0, interval.duration < 32 * 86400 else { throw CalendarConnectionError.invalidRange }
        guard enabled else { throw CalendarConnectionError.accessRequired }
        let version = configurationRevision, selection = selectedIDs
        guard !selection.isEmpty else { throw CalendarConnectionError.selectCalendars }
        guard await provider.access() == .full else { throw CalendarConnectionError.accessRequired }
        try Task.checkCancellation()
        let choices = try await provider.calendars(refresh: false)
        guard version == configurationRevision, enabled, selection == selectedIDs else { throw CalendarConnectionError.changedDuringRead }
        guard selection.isSubset(of: Set(choices.map(\.id))) else { throw CalendarConnectionError.missingCalendars }
        let values = try await provider.occurrences(in: interval, calendarIDs: selection)
        try Task.checkCancellation()
        guard version == configurationRevision, enabled, selection == selectedIDs else { throw CalendarConnectionError.changedDuringRead }
        var seen = Set<String>()
        return CalendarRead(interval: interval, calendarIDs: selection, events: values.filter {
            selection.contains($0.calendarID) && $0.start < interval.end && $0.end > interval.start && $0.start < $0.end && seen.insert($0.id).inserted
        })
    }
    public func meetings(day: Date, settings: PlanningSettings, fullDay: Bool = false) throws -> [PlanBlock] {
        guard enabled else { return [] }
        guard access == .full else { throw CalendarConnectionError.accessRequired }
        guard !selectedIDs.isEmpty else { throw CalendarConnectionError.selectCalendars }
        guard connected, let loadedInterval else {
            throw CalendarConnectionError.changedDuringRead
        }
        return try CalendarRead(interval: loadedInterval, calendarIDs: selectedIDs, events: events).meetings(day: day, settings: settings, fullDay: fullDay)
    }
}
