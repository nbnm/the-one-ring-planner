import Foundation

/// Raw values match Gregorian Calendar.component(.weekday), independent of locale's first weekday.
public enum RoutineWeekday: Int, Codable, CaseIterable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
    public var shortTitle: String { String(title.prefix(3)) }
    public static let workdays: [Self] = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: [Self] = [.saturday, .sunday]
}

public extension Routine {
    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this routine a name." }
        if weekdays.isEmpty { return "Choose at least one day of the week." }
        if minutes < 5 || minutes > 480 { return "Choose a duration between 5 and 480 minutes." }
        if startMinute < 0 || endMinute > 1440 || endMinute <= startMinute { return "The end of the window must be later than its start, within the same day." }
        if endMinute - startMinute < minutes { return "The time window needs room for the full duration." }
        return nil
    }
    func occurs(on day: Date, settings: PlanningSettings) -> Bool {
        enabled && validationMessage == nil && weekdays.contains { $0.rawValue == PlannerDate.calendar(settings).component(.weekday, from: day) }
    }
    var scheduleSummary: String {
        let days = Set(weekdays)
        if days == Set(RoutineWeekday.allCases) { return "Every day" }
        if days == Set(RoutineWeekday.workdays) { return "Weekdays" }
        if days == Set(RoutineWeekday.weekend) { return "Weekends" }
        if days.isEmpty { return "No repeat days" }
        return RoutineWeekday.allCases.filter { days.contains($0) }.map(\.shortTitle).joined(separator: ", ")
    }
}
