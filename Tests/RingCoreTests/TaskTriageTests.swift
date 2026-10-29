import Foundation
import RingCore

final class TaskTriageTests {
    func testIncompleteDropStaysADraft() {
        let inbox = PlannerTask(id: "inbox", title: "Prepare a proposal")
        let proposed = TaskTriage.proposing(inbox, quadrant: .schedule)
        XCTAssertEqual(proposed.quadrant, .schedule)
        XCTAssertEqual(proposed.state, .inbox)
        XCTAssertEqual(TaskTriage.missingRequirements(proposed), [.duration])
        XCTAssertEqual(TaskTriage.readyForPlacement(proposed), nil)
        XCTAssertEqual(inbox.quadrant, nil)
        XCTAssertEqual(inbox.remainingMinutes, nil)
    }
    func testConfirmedEstimateMovesOriginalTaskWithoutLosingContext() {
        var inbox = PlannerTask(id: "inbox", title: "  Prepare a proposal  ", context: "T1A")
        inbox.sourceCaptureID = "raw-capture"; inbox.resumeNote = "Start with the brief"; inbox.dependencies = ["discovery"]
        var proposed = TaskTriage.proposing(inbox, quadrant: .doFirst)
        proposed.remainingMinutes = 30
        let ready = TaskTriage.readyForPlacement(proposed)
        XCTAssertEqual(ready?.state, .ready)
        XCTAssertEqual(ready?.id, inbox.id)
        XCTAssertEqual(ready?.title, "Prepare a proposal")
        XCTAssertEqual(ready?.sourceCaptureID, "raw-capture")
        XCTAssertEqual(ready?.resumeNote, inbox.resumeNote)
        XCTAssertEqual(ready?.dependencies, inbox.dependencies)
        XCTAssertEqual(inbox.state, .inbox)
    }
    func testReprioritizationPreservesExecutionState() {
        for state in [TaskState.ready, .waiting, .inProgress] {
            let existing = PlannerTask(title: "Keep my state", state: state, importance: true, urgency: false, remainingMinutes: 60)
            for quadrant in Quadrant.allCases {
                let moved = TaskTriage.readyForPlacement(TaskTriage.proposing(existing, quadrant: quadrant))
                XCTAssertEqual(moved?.quadrant, quadrant)
                XCTAssertEqual(moved?.state, state)
                XCTAssertEqual(moved?.remainingMinutes, existing.remainingMinutes)
            }
        }
    }
    func testInvalidDetailsAndFinishedTasksCannotBePlaced() {
        var draft = TaskTriage.proposing(PlannerTask(title: " "), quadrant: .delegate)
        draft.remainingMinutes = 15
        XCTAssertTrue(TaskTriage.missingRequirements(draft).contains(.title))
        XCTAssertTrue(TaskTriage.missingRequirements(draft).contains(.minimumBlock))
        XCTAssertEqual(TaskTriage.readyForPlacement(draft), nil)
        draft.title = "An actionable task"; draft.minimumBlockMinutes = 15
        draft.remainingMinutes = 0
        XCTAssertTrue(TaskTriage.missingRequirements(draft).contains(.duration))
        draft.remainingMinutes = 15
        for state in [TaskState.done, .archived] { draft.state = state; XCTAssertEqual(TaskTriage.readyForPlacement(draft), nil) }
    }
    func testConfirmedPrioritySurvivesRepositoryRestart() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data"), local = base.appendingPathComponent("Local")
        let repo = try DataRepository(root: root, localState: local)
        var task = PlannerTask(id: "changing", title: "A persistent priority", state: .ready, importance: true, urgency: true, remainingMinutes: 30)
        try repo.save(tasks: [task], message: "Save task")
        task = TaskTriage.readyForPlacement(TaskTriage.proposing(task, quadrant: .schedule))!
        task.revision += 1
        try repo.save(tasks: [task], message: "Assign task priority")
        let reopened = try DataRepository(root: root, localState: local)
        let saved = try reopened.load(PlannerTask.self, directory: "tasks")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.quadrant, .schedule)
        XCTAssertEqual(saved.first?.state, .ready)
        XCTAssertEqual(saved.first?.revision, 2)
        XCTAssertEqual(try reopened.commitCount(), 2)
    }
}
