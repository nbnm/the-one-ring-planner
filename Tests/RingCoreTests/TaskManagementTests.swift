import Foundation
import RingCore

final class TaskManagementTests {
    let settings = PlanningSettings()
    var day: Date { ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")! }
    var early: Date { PlannerDate.at(480, on: day, settings: settings) }
    func task(_ id: String) -> PlannerTask {
        PlannerTask(id: id, title: id, context: "T1A", tags: ["8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: 60, now: early)
    }
    func plan(_ tasks: [PlannerTask], day: Date? = nil, selection: [String]? = nil) -> DayPlan {
        Scheduler().makePlan(day: day ?? self.day, now: early, tasks: tasks, routines: [], settings: settings, outcomeIDs: tasks.map(\.id), selectedTaskIDs: selection)
    }
    func testInboxAndArchiveRemovePlannedWorkAndPauseRunningWork() {
        var original = task("moving")
        original.notes = "Keep the brief"; original.resumeNote = "Start with the diagram"; original.sourceCaptureID = "source"
        var p = plan([original, task("other")], selection: ["moving", "other"])
        p.status = .local
        let i = p.blocks.firstIndex { $0.taskID == original.id }!
        p.blocks[i].state = .running
        p.blocks[i].actualStartedAt = PlannerDate.at(540, on: day, settings: settings)
        var future = p.blocks[i]; future.id = "pinned-future"; future.state = .planned; future.pinned = true
        p.blocks.append(future)
        var completed = p.blocks[i]; completed.id = "completed-history"; completed.state = .completed; completed.actualMinutes = 15
        p.blocks.append(completed)
        let now = PlannerDate.at(550, on: day, settings: settings)
        for action in [TaskDisposition.inbox, .archive] {
            let change = TaskLifecycle.change(original, to: action, plans: [p], now: now)
            XCTAssertEqual(change.task?.state, action == .inbox ? .inbox : .archived)
            XCTAssertEqual(change.task?.remainingMinutes, 60)
            XCTAssertEqual(change.task?.tags, ["8FDE"])
            XCTAssertEqual(change.task?.notes, original.notes)
            XCTAssertEqual(change.task?.resumeNote, original.resumeNote)
            XCTAssertEqual(change.task?.sourceCaptureID, original.sourceCaptureID)
            XCTAssertEqual(change.task?.revision, original.revision + 1)
            XCTAssertEqual(change.task?.quadrant, action == .inbox ? nil : .schedule)
            let changed = change.plans[0]
            XCTAssertFalse(changed.blocks.contains { $0.taskID == original.id && ($0.state == .planned || $0.state == .running) })
            XCTAssertEqual(changed.blocks.first { $0.id == p.blocks[i].id }?.state, .interrupted)
            XCTAssertEqual(changed.blocks.first { $0.id == p.blocks[i].id }?.actualMinutes, 10)
            XCTAssertEqual(changed.blocks.first { $0.id == completed.id }, completed)
            XCTAssertTrue(changed.blocks.contains { $0.taskID == "other" })
            XCTAssertFalse(changed.outcomeIDs.contains(original.id))
            XCTAssertFalse(changed.selectedTaskIDs?.contains(original.id) ?? true)
            XCTAssertEqual(changed.status, .draft)
            XCTAssertEqual(change.deletingTaskIDs, [])
        }
    }
    func testDeleteCleansEveryPlanAndCaptureWithoutUnblockingDependencies() {
        let deleted = task("deleted")
        var dependent = task("dependent"); dependent.dependencies = [deleted.id]
        let other = task("other")
        var first = plan([deleted, other], selection: [deleted.id, other.id])
        first.previousBlocks = first.blocks
        let tomorrow = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        let second = plan([deleted, other], day: tomorrow)
        let capture = Capture(text: "Create deleted and other", timeZone: settings.timeZone, taskIDs: [deleted.id, other.id], now: early)
        let change = TaskLifecycle.change(deleted, to: .delete, plans: [first, second], captures: [capture], now: early)
        XCTAssertEqual(change.task, nil)
        XCTAssertEqual(change.deletingTaskIDs, [deleted.id])
        XCTAssertEqual(change.plans.count, 2)
        for p in change.plans {
            XCTAssertFalse(p.blocks.contains { $0.taskID == deleted.id })
            XCTAssertFalse(p.previousBlocks?.contains { $0.taskID == deleted.id } ?? false)
            XCTAssertFalse(p.outcomeIDs.contains(deleted.id))
            XCTAssertFalse(p.unscheduled.contains { $0.id == deleted.id })
            XCTAssertTrue(p.blocks.contains { $0.taskID == other.id })
        }
        XCTAssertEqual(change.captures.first?.taskIDs, [other.id])
        XCTAssertEqual(change.captures.first?.text, capture.text)
        let rebuilt = plan([dependent, other])
        XCTAssertFalse(rebuilt.blocks.contains { $0.taskID == dependent.id })
        XCTAssertTrue(rebuilt.unscheduled.contains { $0.id == dependent.id && $0.reason.contains("prerequisite") })
    }
    func testDaySelectionOverridesAutomaticTasksAndFuturePins() {
        let one = task("one"), two = task("two")
        var prior = plan([one, two])
        for index in prior.blocks.indices where prior.blocks[index].taskID == one.id { prior.blocks[index].pinned = true }
        let selected = Scheduler().makePlan(day: day, now: early, tasks: [one, two], routines: [], settings: settings, previous: prior, outcomeIDs: [one.id, two.id], selectedTaskIDs: [two.id, two.id])
        XCTAssertFalse(selected.blocks.contains { $0.taskID == one.id })
        XCTAssertEqual(selected.blocks.filter { $0.taskID == two.id }.reduce(0) { $0 + $1.minutes }, 60)
        XCTAssertEqual(selected.selectedTaskIDs, [two.id])
        XCTAssertEqual(selected.outcomeIDs, [two.id])
        let empty = plan([one, two], selection: [])
        XCTAssertFalse(empty.blocks.contains { $0.kind == .focus })
        XCTAssertEqual(empty.selectedTaskIDs, [])
        XCTAssertTrue(plan([one, two]).blocks.contains { $0.taskID == one.id })
    }
    func testSelectedTasksStillSeeDependenciesAndKeepExecutionHistory() {
        var done = task("done"); done.state = .done
        var dependent = task("dependent"); dependent.dependencies = [done.id]
        let result = plan([done, dependent], selection: [dependent.id])
        XCTAssertTrue(result.blocks.contains { $0.taskID == dependent.id })
        var prior = plan([task("one"), task("two")])
        let one = prior.blocks.firstIndex { $0.taskID == "one" }!
        let two = prior.blocks.firstIndex { $0.taskID == "two" }!
        prior.blocks[one].state = .completed
        prior.blocks[two].state = .running
        let rebuilt = Scheduler().makePlan(day: day, now: early, tasks: [task("one"), task("two")], routines: [], settings: settings, previous: prior, selectedTaskIDs: [])
        XCTAssertTrue(rebuilt.blocks.contains(prior.blocks[one]))
        XCTAssertTrue(rebuilt.blocks.contains(prior.blocks[two]))
        XCTAssertFalse(rebuilt.blocks.contains { $0.kind == .focus && $0.state == .planned })
    }
    func testSelectionSurvivesRestartAndLegacyPlansStayAutomatic() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        let first = plan([task("one"), task("two")], selection: ["two"])
        let next = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        let second = plan([task("one"), task("two")], day: next, selection: [])
        try repo.save(plans: [first, second], message: "Save date-specific choices")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        let loaded = try reopened.load(DayPlan.self, directory: "plans")
        XCTAssertEqual(loaded.first { $0.id == first.id }?.selectedTaskIDs, ["two"])
        XCTAssertEqual(loaded.first { $0.id == second.id }?.selectedTaskIDs, [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(first)) as! [String: Any]
        legacy.removeValue(forKey: "selectedTaskIDs"); legacy["schemaVersion"] = 1
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(DayPlan.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.selectedTaskIDs, nil)
    }
    func testDeletionTransactionAndInterruptedRecoveryAreIdempotent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        let deleted = task("deleted"), other = task("other")
        let original = plan([deleted, other])
        let capture = Capture(text: "Two original tasks", timeZone: settings.timeZone, taskIDs: [deleted.id, other.id], now: early)
        try repo.save(tasks: [deleted, other], captures: [capture], plan: original, message: "Initial tasks")
        let change = TaskLifecycle.change(deleted, to: .delete, plans: [original], captures: [capture], now: early)
        try repo.save(captures: change.captures, plans: change.plans, deletingTaskIDs: change.deletingTaskIDs, message: "Delete task")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.load(PlannerTask.self, directory: "tasks").map(\.id), [other.id])
        XCTAssertFalse(try reopened.load(DayPlan.self, directory: "plans")[0].blocks.contains { $0.taskID == deleted.id })
        XCTAssertEqual(try reopened.load(Capture.self, directory: "captures")[0].taskIDs, [other.id])
        XCTAssertEqual(try reopened.commitCount(), 2)
        // Replaying a journal after its Git commit must succeed without a duplicate commit.
        let journal: [String: Any] = ["writes": [], "deletes": ["tasks/deleted.json"], "message": "Recover deletion"]
        try JSONSerialization.data(withJSONObject: journal).write(to: repo.localState.appendingPathComponent("pending-write.json"))
        let recovered = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try recovered.commitCount(), 2)
        // Recovery must also finish a deletion interrupted after the file was removed.
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("tasks/other.json"))
        let partial: [String: Any] = ["writes": [], "deletes": ["tasks/other.json"], "message": "Recover partial deletion"]
        try JSONSerialization.data(withJSONObject: partial).write(to: repo.localState.appendingPathComponent("pending-write.json"))
        let finished = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try finished.load(PlannerTask.self, directory: "tasks"), [])
        XCTAssertEqual(try finished.commitCount(), 3)
        XCTAssertThrowsError(try finished.save(deletingTaskIDs: ["../../settings/planning"], message: "Reject unsafe path"))
    }
}
