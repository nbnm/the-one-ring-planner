import Foundation
import RingCore

struct TodayTaskTests {
    let settings = PlanningSettings()
    let now = ISO8601DateFormatter().date(from: "2026-11-03T15:15:00Z")!
    func task(_ id: String = "ferry") -> PlannerTask {
        var task = PlannerTask(id: id, title: "Secure the Bucklebury ferry", notes: "Wait for the Fellowship", tags: ["The Shire"], state: .inProgress, importance: true, urgency: false, remainingMinutes: 70, now: now)
        task.sourceCaptureID = "source"; task.resumeNote = "Check the eastern bank"; task.dependencies = ["map"]
        return task
    }
    func testBacklogRemovesAllUnstartedWorkAndKeepsPriorityAndHistory() {
        var original = task(); original.dependencies = []
        var plan = Scheduler().makePlan(day: now, now: PlannerDate.at(480, on: now, settings: settings), tasks: [original], routines: [], settings: settings)
        let index = plan.blocks.firstIndex { $0.taskID == original.id }!
        plan.blocks[index].state = .running; plan.blocks[index].actualStartedAt = now.addingTimeInterval(-600)
        var history = plan.blocks[index]; history.id = "earlier"; history.state = .completed; history.actualMinutes = 15
        plan.blocks.append(history)
        var future = Scheduler().makePlan(day: now.addingTimeInterval(86400), now: now, tasks: [original], routines: [], settings: settings)
        for i in future.blocks.indices where future.blocks[i].taskID == original.id { future.blocks[i].pinned = true }
        future.publication = CalendarPublication(plan: future, workspaceID: "shire", destination: .init(id: "example", title: "Fictional", accountID: "example"), timeZone: settings.timeZone)
        future.publication!.state = .published
        let result = TaskLifecycle.change(original, to: .backlog, plans: [plan, future], now: now)
        XCTAssertEqual(result.task?.state, .ready); XCTAssertEqual(result.task?.quadrant, .schedule)
        XCTAssertEqual(result.task?.remainingMinutes, 70); XCTAssertEqual(result.task?.notes, original.notes)
        XCTAssertEqual(result.task?.tags, original.tags); XCTAssertEqual(result.task?.sourceCaptureID, original.sourceCaptureID)
        XCTAssertEqual(result.task?.resumeNote, original.resumeNote); XCTAssertTrue(result.completions.isEmpty)
        XCTAssertEqual(result.plans.count, 2)
        XCTAssertTrue(result.plans.allSatisfy { !$0.blocks.contains { $0.taskID == original.id && ($0.state == .planned || $0.state == .running) } })
        let changed = result.plans.first { $0.id == plan.id }!
        XCTAssertEqual(changed.blocks.first { $0.id == history.id }, history)
        XCTAssertEqual(changed.blocks.first { $0.id == plan.blocks[index].id }?.actualMinutes, 10)
        XCTAssertEqual(changed.blocks.first { $0.id == plan.blocks[index].id }?.state, .interrupted)
        let changedFuture = result.plans.first { $0.id == future.id }!
        XCTAssertEqual(changedFuture.publication?.invalidatingChanges(in: changedFuture, timeZone: settings.timeZone).state, .needsConfirmation)
    }
    func testMarkIncompleteRestoresEffortAndPriorityWithoutLosingCompletion() throws {
        for quadrant in Quadrant.allCases {
            var original = task(); original.importance = quadrant == .doFirst || quadrant == .schedule; original.urgency = quadrant == .doFirst || quadrant == .delegate
            let done = TaskLifecycle.change(original, to: .complete, plans: [], now: now)
            let entry = done.completions[0]
            let undone = try TaskHistory.restore(entry, current: done.task, completions: [entry], now: now.addingTimeInterval(60), destination: .backlog)
            XCTAssertEqual(undone.task.state, .ready); XCTAssertEqual(undone.task.quadrant, quadrant)
            XCTAssertEqual(undone.task.remainingMinutes, 70); XCTAssertEqual(undone.task.dependencies, original.dependencies)
            XCTAssertEqual(undone.task.sourceCaptureID, original.sourceCaptureID); XCTAssertEqual(undone.task.createdAt, original.createdAt)
            XCTAssertEqual(undone.completion.taskSnapshot, original); XCTAssertEqual(undone.completion.completedAt, now)
            XCTAssertEqual(undone.completion.restoredAt, now.addingTimeInterval(60)); XCTAssertEqual(undone.task.completionID, nil)
            XCTAssertThrowsError(try TaskHistory.restore(undone.completion, current: undone.task, completions: [undone.completion], now: now, destination: .backlog))
            let inbox = try TaskHistory.restore(entry, current: done.task, completions: [entry], now: now)
            XCTAssertEqual(inbox.task.state, .inbox); XCTAssertEqual(inbox.task.quadrant, nil)
        }
    }
    func testTodayShowsActualCompletionDayAcrossDSTAndHidesRestoredEntries() throws {
        let parser = ISO8601DateFormatter(), day = parser.date(from: "2026-11-01T12:00:00Z")!
        // Both 01:30 occurrences belong to the same 25-hour Toronto day.
        let first = TaskLifecycle.change(task("first"), to: .complete, plans: [], now: parser.date(from: "2026-11-01T05:30:00Z")!)
        let second = TaskLifecycle.change(task("second"), to: .complete, plans: [], now: parser.date(from: "2026-11-01T06:30:00Z")!)
        let outside = TaskLifecycle.change(task("outside"), to: .complete, plans: [], now: parser.date(from: "2026-11-02T05:00:00Z")!)
        let tasks = [first.task!, second.task!, outside.task!]
        let entries = first.completions + second.completions + outside.completions
        XCTAssertEqual(TaskHistory.completed(on: day, tasks: tasks, completions: entries, settings: settings).map(\.taskID), ["second", "first"])
        let restored = try TaskHistory.restore(first.completions[0], current: first.task, completions: entries, now: now, destination: .backlog)
        let current = [restored.task, second.task!, outside.task!]
        XCTAssertEqual(TaskHistory.completed(on: day, tasks: current, completions: [restored.completion] + second.completions + outside.completions, settings: settings).map(\.taskID), ["second"])
        XCTAssertTrue(TaskHistory.completed(on: day, tasks: [], completions: entries, settings: settings).isEmpty)
    }
    func testBacklogRestorationSurvivesRestartWithCompletionEvidence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("today-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try DataRepository(root: folder.appendingPathComponent("Data"), localState: folder.appendingPathComponent("Local"))
        let done = TaskLifecycle.change(task(), to: .complete, plans: [], now: now)
        try repo.save(tasks: [done.task!], completions: done.completions, message: "Complete")
        let undone = try TaskHistory.restore(done.completions[0], current: done.task, completions: done.completions, now: now, destination: .backlog)
        try repo.save(tasks: [undone.task], completions: [undone.completion], message: "Mark incomplete")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try reopened.load(PlannerTask.self, directory: "tasks"), [undone.task])
        XCTAssertEqual(try reopened.load(TaskCompletion.self, directory: "completions"), [undone.completion])
        XCTAssertEqual(try reopened.commitCount(), 2)
    }
}
