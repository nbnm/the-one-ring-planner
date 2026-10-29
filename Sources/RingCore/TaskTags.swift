import Foundation

public enum TaskTags {
    public static func normalize(_ tags: [String], known: [String] = []) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.isEmpty else { return nil }
            let canonical = known.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            guard seen.insert(canonical.lowercased()).inserted else { return nil }
            return canonical
        }
    }
    public static func all(in tasks: [PlannerTask]) -> [String] {
        normalize(tasks.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum TaskTagFilter: Hashable {
    case all, untagged, tag(String)
    public func matches(_ task: PlannerTask) -> Bool {
        switch self {
        case .all: return true
        case .untagged: return task.tags.isEmpty
        case .tag(let name): return task.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
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
