import Foundation
import RingCore

extension PlannerStore {
    /// Saves first, then classifies new inventory items. User edits always win over late AI results.
    func categorizeInventoryTask(_ snapshot: PlannerTask, offerSlot: Bool = false) {
        guard TaskArea.from(snapshot.tags) == nil else { if offerSlot { offerTimeSlot(for: snapshot) }; return }
        Task {
            do {
                let area: TaskArea
                if isDemo { area = .work }
                else {
                    let connection = captureAI.connection
                    let key = try await captureAI.apiKey()
                    try await library.consumeBudget()
                    let input = InboxItem(text: snapshot.title + "\n" + snapshot.notes + "\n" + snapshot.context)
                    let result = try await LibraryAIClient().classifyInbox(input, extractedText: "", knownTags: knownTags, connection: connection, key: key)
                    guard captureAI.connection == connection else { return }
                    area = TaskArea.from(result.tags) ?? .work
                }
                guard let current = tasks.first(where: { $0.id == snapshot.id }), current.revision == snapshot.revision, TaskArea.from(current.tags) == nil else { return }
                var value = current; value.area = area; value.revision += 1; value.updatedAt = Date()
                if persist(message: "Categorize task as " + area.rawValue, tasks: [value], apply: { if let index = self.tasks.firstIndex(where: { $0.id == value.id }) { self.tasks[index] = value } }), offerSlot { offerTimeSlot(for: value) }
            } catch {
                showNotice("Task saved · AI categorization unavailable. Choose Work or Personal in task details.")
                if offerSlot, let current = tasks.first(where: { $0.id == snapshot.id }), current.revision == snapshot.revision { offerTimeSlot(for: current) }
            }
        }
    }
}
