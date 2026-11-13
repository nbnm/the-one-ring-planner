import Foundation

public enum TaskArea: String, Codable, CaseIterable, Sendable {
    case work = "Work", personal = "Personal"
    public static func from(_ tags: [String]) -> Self? {
        tags.reversed().compactMap { tag in allCases.first { $0.rawValue.caseInsensitiveCompare(tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))) == .orderedSame } }.first
    }
    public func applying(to tags: [String]) -> [String] {
        TaskTags.normalize(tags.filter { Self.from([$0]) == nil } + [rawValue])
    }
}
extension PlannerTask {
    /// Legacy unclassified tasks keep their existing work schedule until explicitly changed.
    public var area: TaskArea { get { TaskArea.from(tags) ?? .work } set { tags = newValue.applying(to: tags) } }
}
public enum TaskTags {
    public static func normalize(_ tags: [String], known: [String] = []) -> [String] {
        var seen = Set<String>()
        let area = TaskArea.from(tags)
        return tags.compactMap { tag in
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.isEmpty else { return nil }
            let canonical = TaskArea.from([name])?.rawValue ?? known.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            guard TaskArea.from([canonical]).map({ $0 == area }) ?? true, seen.insert(canonical.lowercased()).inserted else { return nil }
            return canonical
        }
    }
    public static func all(in tasks: [PlannerTask]) -> [String] {
        var seen = Set<String>()
        return tasks.flatMap { normalize($0.tags) }.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum TaskTagFilter: Hashable {
    case all, untagged, tag(String)
    public func matches(_ task: PlannerTask) -> Bool {
        switch self {
        case .all: return true
        case .untagged: return task.tags.isEmpty
        case .tag(let name): if let area = TaskArea.from([name]) { return task.area == area }; return task.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}

public struct TaskTagGroup: Identifiable {
    public var id: String
    public var title: String?
    public var tasks: [PlannerTask]
    public static func make(_ tasks: [PlannerTask], grouped: Bool, filter: TaskTagFilter = .all) -> [Self] {
        let filtered = tasks.filter { filter.matches($0) }
        guard grouped else { return [Self(id: "all", title: nil, tasks: filtered)] }
        let names = TaskTags.all(in: filtered)
        var groups: [Self] = names.compactMap { name in
            let members = filtered.filter { $0.tags.first?.caseInsensitiveCompare(name) == .orderedSame }
            return members.isEmpty ? nil : Self(id: name.lowercased(), title: name, tasks: members)
        }
        let untagged = filtered.filter { $0.tags.isEmpty }
        if !untagged.isEmpty { groups.append(Self(id: "", title: "Untagged", tasks: untagged)) }
        return groups
    }
}

extension PlanningSettings {
    public func taskWindow(_ area: TaskArea, on day: Date) -> (start: Int, end: Int) {
        guard area == .personal else { return (workStart, workEnd) }
        let p = personalAvailability ?? PersonalAvailability()
        return PlannerDate.calendar(self).isDateInWeekend(day) ? (p.weekendStart, p.weekendEnd) : (p.weekdayStart, p.weekdayEnd)
    }
}
