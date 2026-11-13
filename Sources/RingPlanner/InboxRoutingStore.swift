import SwiftUI
import RingCore

extension PlannerStore {
    func captureIntoInbox() async -> Bool {
        guard taskCapture.preparing == 0 else { return false }
        let text = inboxDraft, files = taskCapture.files
        if await sharedInbox.capture(id: taskCapture.captureID, createdAt: taskCapture.createdAt, text: text, files: files) {
            if inboxDraft == text { inboxDraft = "" }; taskCapture.removeConfirmed(files); taskCapture.rotateIdentity()
            showNotice("Saved to Inbox · sorting in the background"); return true
        }
        return false
    }
    func placeInbox(_ item: InboxItem, in quadrant: Quadrant) {
        guard let current = sharedInbox.active.first(where: { $0.id == item.id }) else { return }
        let proposed = TaskTriage.proposing(current.task(settings: settings), quadrant: quadrant)
        priorityReview = PriorityReviewRequest(task: proposed, originalRevision: current.revision, inboxItem: current)
    }
    @discardableResult func commitInboxPriority(_ task: PlannerTask, item: InboxItem) -> Bool {
        guard let repository else { return false }
        do {
            let routed = try repository.routeInbox(item, as: .task, task: task, settings: settings)
            sharedInbox.accept(routed.item)
            if let task = routed.task { tasks.removeAll { $0.id == task.id }; tasks.append(task); categorizeInventoryTask(task, offerSlot: task.quadrant == .schedule) }
            library.scheduleBackup(); showNotice("Moved to the priority matrix"); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func placeInboxInLibrary(_ item: InboxItem) {
        guard let repository else { return }
        Task {
            do {
                let planning = settings
                let routed = try await Task.detached { try repository.routeInbox(item, as: .note, settings: planning) }.value
                sharedInbox.accept(routed.item)
                if let note = routed.note { library.accept(note); await library.enqueue(note) }
                library.scheduleBackup(); showNotice("Moved to Library")
            } catch { self.error = error.localizedDescription }
        }
    }
    func moveInboxTaskToLibrary(_ task: PlannerTask) {
        guard task.state == .inbox, let repository else { return }
        guard !publishingCalendar && !calendarEditSending else { error = "Wait for the calendar update to finish, then move this item."; return }
        do {
            // Demo tasks are normally held in memory; persist this fictional snapshot before exercising the real move.
            if isDemo { let stored = try repository.load(PlannerTask.self, directory: "tasks"); if !stored.contains(where: { $0.id == task.id }) { try repository.save(tasks: [task], message: "Seed fictional Inbox task") } }
            let moved = try repository.moveLegacyInboxTaskToLibrary(task)
            tasks.removeAll { $0.id == task.id }; plans = moved.plans; calendarEdits = moved.edits; calendarGridRevision = UUID(); library.accept(moved.note)
            Task { await library.enqueue(moved.note) }; library.scheduleBackup(); showNotice("Moved to Library")
        } catch { self.error = error.localizedDescription }
    }
}
