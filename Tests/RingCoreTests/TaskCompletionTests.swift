import Foundation
import RingCore

struct TaskCompletionTests {
    let settings = PlanningSettings()
    let now = ISO8601DateFormatter().date(from: "2026-10-27T18:23:00Z")!
    func task(_ quadrant: Quadrant = .schedule) -> PlannerTask {
        var task = PlannerTask(id: "complete-task", title: "Review the 8FDE proposal", context: "T1A", notes: "Keep the delivery brief", tags: ["8FDE"], state: .ready, importance: quadrant == .doFirst || quadrant == .schedule, urgency: quadrant == .doFirst || quadrant == .delegate, remainingMinutes: 60, now: now.addingTimeInterval(-86400))
        task.sourceCaptureID = "capture"; task.resumeNote = "Confirm the assumptions"; task.dependencies = ["discovery"]
        return task
    }
    func testCompletionFromEveryQuadrantIgnoresFuturePlannedDate() {
        for quadrant in Quadrant.allCases {
            let task = task(quadrant), future = now.addingTimeInterval(86400)
            var plannedTask = task; plannedTask.dependencies = []
            var plan = Scheduler().makePlan(day: future, now: now, tasks: [plannedTask], routines: [], settings: settings, outcomeIDs: [task.id], selectedTaskIDs: [task.id])
            for i in plan.blocks.indices where plan.blocks[i].taskID == task.id { plan.blocks[i].pinned = true }
            // Q4 deliberately has no automatic plan; explicit task completion must still work.
            let result = TaskLifecycle.change(task, to: .complete, plans: [plan], now: now)
            let completed = result.task!
            XCTAssertEqual(completed.state, .done); XCTAssertEqual(completed.completedAt, now); XCTAssertEqual(completed.remainingMinutes, 0)
            XCTAssertEqual(completed.quadrant, quadrant); XCTAssertEqual(completed.createdAt, task.createdAt)
            XCTAssertEqual(completed.revision, task.revision + 1)
            XCTAssertEqual(result.completions.count, 1); XCTAssertEqual(result.completions[0].completedAt, now)
            XCTAssertEqual(result.completions[0].taskSnapshot, task); XCTAssertEqual(completed.completionID, result.completions[0].id)
            for p in result.plans { XCTAssertFalse(p.blocks.contains { $0.taskID == task.id }); XCTAssertFalse(p.outcomeIDs.contains(task.id)); XCTAssertFalse(p.selectedTaskIDs?.contains(task.id) ?? true) }
            let repeated = TaskLifecycle.change(completed, to: .complete, plans: [plan], now: future)
            XCTAssertEqual(repeated.task, completed); XCTAssertTrue(repeated.completions.isEmpty); XCTAssertTrue(repeated.plans.isEmpty)
        }
    }
    func testCompletionClosesRunningWorkAndPreservesPriorHistoryAcrossPlans() {
        var original = task(); original.dependencies = []
        var other = original; other.id = "other"; other.title = "Unrelated work"
        var today = Scheduler().makePlan(day: now, now: PlannerDate.at(480, on: now, settings: settings), tasks: [original, other], routines: [], settings: settings)
        let i = today.blocks.firstIndex { $0.taskID == original.id }!
        today.blocks[i].state = .running; today.blocks[i].actualStartedAt = now.addingTimeInterval(-12 * 60)
        var previous = today.blocks[i]; previous.id = "earlier-completed"; previous.state = .completed; previous.actualMinutes = 9
        today.blocks.append(previous); today.previousBlocks = [previous]
        let tomorrow = Scheduler().makePlan(day: now.addingTimeInterval(86400), now: now, tasks: [original, other], routines: [], settings: settings)
        let result = TaskLifecycle.change(original, to: .complete, plans: [today, tomorrow], now: now)
        XCTAssertEqual(result.plans.count, 2)
        let changed = result.plans.first { $0.id == today.id }!
        XCTAssertEqual(changed.blocks.first { $0.id == today.blocks[i].id }?.state, .completed)
        XCTAssertEqual(changed.blocks.first { $0.id == today.blocks[i].id }?.actualMinutes, 12)
        XCTAssertEqual(changed.blocks.first { $0.id == previous.id }, previous)
        XCTAssertEqual(changed.previousBlocks, today.previousBlocks)
        XCTAssertEqual(changed.blocks.filter { $0.taskID == other.id }, today.blocks.filter { $0.taskID == other.id })
        XCTAssertTrue(result.plans.allSatisfy { !$0.blocks.contains { $0.taskID == original.id && ($0.state == .planned || $0.state == .running) } })
    }
    func testRestoreRetainsSnapshotsAcrossMultipleCompletionCycles() throws {
        let original = task(), first = TaskLifecycle.change(task(), to: .complete, plans: [], now: now)
        let entry = first.completions[0]
        let reopened = try TaskHistory.restore(entry, current: first.task, completions: [entry], now: now.addingTimeInterval(60))
        XCTAssertEqual(reopened.task.id, original.id); XCTAssertEqual(reopened.task.state, .inbox); XCTAssertEqual(reopened.task.remainingMinutes, 60)
        XCTAssertEqual(reopened.task.quadrant, nil); XCTAssertEqual(reopened.task.completedAt, nil); XCTAssertEqual(reopened.task.completionID, nil)
        XCTAssertEqual(reopened.task.tags, original.tags); XCTAssertEqual(reopened.task.notes, original.notes)
        XCTAssertEqual(reopened.task.createdAt, original.createdAt); XCTAssertEqual(reopened.task.sourceCaptureID, original.sourceCaptureID)
        XCTAssertEqual(reopened.completion.taskSnapshot, original); XCTAssertEqual(reopened.completion.completedAt, now)
        XCTAssertEqual(reopened.completion.restoredAt, now.addingTimeInterval(60))
        XCTAssertThrowsError(try TaskHistory.restore(reopened.completion, current: reopened.task, completions: [reopened.completion], now: now))
        var renamed = reopened.task; renamed.title = "Finish revised proposal"
        let second = TaskLifecycle.change(renamed, to: .complete, plans: [], now: now.addingTimeInterval(120))
        let history = [reopened.completion, second.completions[0]]
        XCTAssertEqual(history[0].taskSnapshot.title, original.title); XCTAssertEqual(history[1].taskSnapshot.title, renamed.title)
        XCTAssertEqual(TaskHistory.latest(taskID: original.id, completions: history)?.id, history[1].id)
        XCTAssertThrowsError(try TaskHistory.restore(entry, current: second.task, completions: history, now: now))
        let recoveredDeleted = try TaskHistory.restore(history[1], current: nil, completions: history, now: now.addingTimeInterval(180))
        XCTAssertEqual(recoveredDeleted.task.id, original.id); XCTAssertEqual(recoveredDeleted.task.title, renamed.title)
    }
    func testLegacyMigrationKeepsUnknownDatesHonestAndIsIdempotent() throws {
        var old = task(); old.state = .done; old.remainingMinutes = 0
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var data = try JSONSerialization.jsonObject(with: encoder.encode(old)) as! [String: Any]
        data["schemaVersion"] = 2; data.removeValue(forKey: "completedAt"); data.removeValue(forKey: "completionID")
        let decoded = try decoder.decode(PlannerTask.self, from: JSONSerialization.data(withJSONObject: data))
        let migration = TaskHistory.migratingLegacy(tasks: [decoded], completions: [], now: now)
        XCTAssertEqual(migration.completions.count, 1); XCTAssertEqual(migration.completions[0].completedAt, nil)
        XCTAssertEqual(migration.tasks[0].updatedAt, old.updatedAt)
        XCTAssertEqual(migration.tasks[0].completionID, migration.completions[0].id)
        let again = TaskHistory.migratingLegacy(tasks: migration.tasks, completions: migration.completions, now: now.addingTimeInterval(600))
        XCTAssertTrue(again.tasks.isEmpty); XCTAssertTrue(again.completions.isEmpty)
        let restored = try TaskHistory.restore(migration.completions[0], current: migration.tasks[0], completions: migration.completions, now: now)
        XCTAssertEqual(restored.task.remainingMinutes, 25); XCTAssertEqual(restored.completion.completedAt, nil)
    }
    func testCompletionAndRestorationSurviveRestartAndInterruptedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DataRepository(root: root.appendingPathComponent("Data"), localState: root.appendingPathComponent("Local"))
        let change = TaskLifecycle.change(task(), to: .complete, plans: [], now: now)
        try repo.save(tasks: [change.task!], completions: change.completions, message: "Complete task")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.load(TaskCompletion.self, directory: "completions"), change.completions)
        XCTAssertEqual(try reopened.load(PlannerTask.self, directory: "tasks"), [change.task!])
        let restore = try TaskHistory.restore(change.completions[0], current: change.task, completions: change.completions, now: now.addingTimeInterval(60))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let writes: [[String: Any]] = [
            ["path": "tasks/\(restore.task.id).json", "content": try encoder.encode(restore.task).base64EncodedString()],
            ["path": "completions/\(restore.completion.id).json", "content": try encoder.encode(restore.completion).base64EncodedString()]
        ]
        try JSONSerialization.data(withJSONObject: ["writes": writes, "message": "Recover interrupted restoration"]).write(to: repo.localState.appendingPathComponent("pending-write.json"))
        let recovered = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try recovered.load(TaskCompletion.self, directory: "completions"), [restore.completion])
        XCTAssertEqual(try recovered.load(PlannerTask.self, directory: "tasks"), [restore.task])
        XCTAssertEqual(try recovered.commitCount(), 2)
        try recovered.save(deletingTaskIDs: [restore.task.id], message: "Remove active task, retain completion history")
        XCTAssertEqual(try recovered.load(TaskCompletion.self, directory: "completions").count, 1)
    }
    func testTimelineCompletionRecordsBlockAndInvalidatesFutureBookings() {
        var original = task(); original.dependencies = []
        var today = Scheduler().makePlan(day: now, now: PlannerDate.at(480, on: now, settings: settings), tasks: [original], routines: [], settings: settings)
        let index = today.blocks.firstIndex { $0.taskID == original.id }!
        today.blocks[index].state = .completed
        let future = now.addingTimeInterval(86400)
        var tomorrow = Scheduler().makePlan(day: future, now: now, tasks: [original], routines: [], settings: settings)
        tomorrow.publication = CalendarPublication(plan: tomorrow, workspaceID: "test-workspace", destination: PublicationDestination(id: "calendar", title: "Test", accountID: "test"), timeZone: settings.timeZone)
        tomorrow.publication!.state = .published
        let result = TaskLifecycle.change(original, to: .complete, plans: [today, tomorrow], now: now, completedBlockID: today.blocks[index].id)
        XCTAssertEqual(result.completions[0].blockID, today.blocks[index].id)
        let updatedFuture = result.plans.first { $0.id == tomorrow.id }!
        let invalidated = updatedFuture.publication!.invalidatingChanges(in: updatedFuture, timeZone: settings.timeZone)
        XCTAssertEqual(invalidated.state, .needsConfirmation)
        XCTAssertEqual(invalidated.desired, tomorrow.publication!.desired)
        XCTAssertFalse(updatedFuture.blocks.contains { $0.taskID == original.id })
    }
}
