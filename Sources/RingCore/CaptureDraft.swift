import Foundation

public struct CaptureDraft: Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var included = true
    public var title: String
    public var notes: String
    public var tags: [String]
    public init(title: String = "", notes: String = "", tags: [String] = []) {
        self.title = title; self.notes = notes; self.tags = TaskTags.normalize(tags)
    }
}

public enum CaptureDraftError: LocalizedError {
    case noSelection, invalidTitle, tooManyTasks, existingTaskNotInbox
    public var errorDescription: String? {
        switch self {
        case .noSelection: return "Select at least one task to add."
        case .invalidTitle: return "Give every selected task a title of 160 characters or fewer. Put extra detail in its notes."
        case .tooManyTasks: return "Review up to 12 tasks at a time."
        case .existingTaskNotInbox: return "Only Inbox captures can be split. Edit a planned task's details directly."
        }
    }
}

public struct ReviewedCapture {
    public let tasks: [PlannerTask]
    public let capture: Capture
    public init(source: String, drafts: [CaptureDraft], settings: PlanningSettings, knownTags: [String] = [], replacing original: PlannerTask? = nil, now: Date = Date()) throws {
        let selected = drafts.filter(\.included)
        guard !selected.isEmpty else { throw CaptureDraftError.noSelection }
        guard selected.count <= 12 else { throw CaptureDraftError.tooManyTasks }
        guard selected.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).count <= 160 }) else { throw CaptureDraftError.invalidTitle }
        var tasks = selected.map { draft in
            var task = PlannerTask(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                   notes: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                                   tags: TaskTags.normalize(draft.tags, known: knownTags), now: now)
            task.minimumBlockMinutes = settings.minimumFocusMinutes
            return task
        }
        if var original {
            guard original.state == .inbox else { throw CaptureDraftError.existingTaskNotInbox }
            original.title = tasks[0].title; original.notes = tasks[0].notes; original.tags = tasks[0].tags
            original.updatedAt = now; original.revision += 1
            tasks[0] = original
        }
        let capture = Capture(text: source, timeZone: settings.timeZone, taskIDs: tasks.map(\.id), now: now)
        for index in tasks.indices { tasks[index].sourceCaptureID = capture.id }
        self.tasks = tasks; self.capture = capture
    }
}
