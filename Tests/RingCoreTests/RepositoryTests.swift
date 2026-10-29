import Foundation
import RingCore

final class RepositoryTests {
    func testCaptureAndTaskSurviveRestartWithSeparateGitHistory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data"), local = base.appendingPathComponent("Local")
        let repo = try DataRepository(root: root, localState: local)
        let task = PlannerTask(title: "Keep literal $(whoami) and `text` safely")
        let capture = Capture(text: task.title, timeZone: "America/Toronto", taskID: task.id)
        try repo.save(tasks: [task], captures: [capture], message: "Capture inbox item")
        XCTAssertEqual(try repo.commitCount(), 1)
        let restarted = try DataRepository(root: root, localState: local)
        XCTAssertEqual(try restarted.load(PlannerTask.self, directory: "tasks").first?.title, task.title)
        XCTAssertEqual(try restarted.load(Capture.self, directory: "captures").first?.text, capture.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("pending-write.json").path))
    }
    func testWriteAheadJournalRecoversInterruptedSave() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Data"), local = base.appendingPathComponent("Local")
        _ = try DataRepository(root: root, localState: local)
        let t = PlannerTask(id: "recovered", title: "Recover me")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(t)
        let journal: [String: Any] = ["writes": [["path": "tasks/recovered.json", "content": data.base64EncodedString()]], "message": "Recover interrupted capture"]
        try JSONSerialization.data(withJSONObject: journal).write(to: local.appendingPathComponent("pending-write.json"))
        let recovered = try DataRepository(root: root, localState: local)
        XCTAssertEqual(try recovered.load(PlannerTask.self, directory: "tasks").first?.id, "recovered")
        XCTAssertEqual(try recovered.commitCount(), 1)
        _ = try DataRepository(root: root, localState: local)
        XCTAssertEqual(try recovered.commitCount(), 1)
    }
    func testCorruptFilesArePreservedAndReported() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        try repo.save(tasks: [PlannerTask(id: "bad", title: "A task")], message: "Save")
        let file = repo.root.appendingPathComponent("tasks/bad.json")
        try Data("{broken".utf8).write(to: file)
        XCTAssertThrowsError(try repo.load(PlannerTask.self, directory: "tasks"))
        XCTAssertEqual(try String(contentsOf: file), "{broken")
    }
}
