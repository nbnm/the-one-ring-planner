import Foundation
import RingCore

struct CaptureTests {
    func testLegacyTasksAndTagsSurviveRestart() throws {
        var task = PlannerTask(title: "Existing task", context: "Delivery", state: .ready, importance: true, urgency: false, remainingMinutes: 60, now: Date(timeIntervalSince1970: 1700000000))
        task.resumeNote = "Keep this note"; task.dependencies = ["other-task"]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(task)) as! [String: Any]
        json.removeValue(forKey: "notes"); json.removeValue(forKey: "tags"); json["schemaVersion"] = 1
        let migrated = try decoder.decode(PlannerTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.id, task.id); XCTAssertEqual(migrated.remainingMinutes, 60)
        XCTAssertEqual(migrated.dependencies, task.dependencies); XCTAssertEqual(migrated.resumeNote, task.resumeNote)
        XCTAssertTrue(migrated.tags.isEmpty); XCTAssertEqual(migrated.notes, "")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        var tagged = migrated; tagged.tags = ["Rogers", "8FDE"]; tagged.notes = "Keep the discovery findings."
        try repo.save(tasks: [tagged], message: "Add project tags")
        let restarted = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try restarted.load(PlannerTask.self, directory: "tasks"), [tagged])
    }
    func testReviewedSplitSavesSelectedTasksAndSourceTogether() throws {
        var ignored = CaptureDraft(title: "Do not create this"); ignored.included = false
        let drafts = [CaptureDraft(title: " Review Rogers proposal ", notes: "For T1A", tags: ["rogers", "#Rogers"]), ignored, CaptureDraft(title: "Update roadmap", tags: ["8FDE"])]
        let raw = "So, create a task to review the proposal and also update the roadmap."
        let batch = try ReviewedCapture(source: raw, drafts: drafts, settings: PlanningSettings(), knownTags: ["Rogers"], now: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(batch.tasks.count, 2); XCTAssertEqual(batch.tasks.first?.title, "Review Rogers proposal")
        XCTAssertEqual(batch.tasks.first?.tags, ["Rogers"])
        XCTAssertTrue(batch.tasks.allSatisfy { $0.state == .inbox && $0.remainingMinutes == nil && $0.importance == nil && $0.sourceCaptureID == batch.capture.id })
        XCTAssertEqual(batch.capture.taskIDs, batch.tasks.map(\.id)); XCTAssertEqual(batch.capture.text, raw)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        try repo.save(tasks: batch.tasks, captures: [batch.capture], message: "Confirm two task drafts")
        XCTAssertEqual(try repo.load(Capture.self, directory: "captures"), [batch.capture])
        XCTAssertEqual(Set(try repo.load(PlannerTask.self, directory: "tasks").map(\.id)), Set(batch.tasks.map(\.id)))
        XCTAssertEqual(try repo.commitCount(), 1)
        XCTAssertThrowsError(try ReviewedCapture(source: raw, drafts: [ignored], settings: PlanningSettings()))
        XCTAssertThrowsError(try ReviewedCapture(source: raw, drafts: [drafts[0], CaptureDraft()], settings: PlanningSettings()))
    }
    func testTagGroupingAndFilteringNeverDuplicateOrHideUntagged() {
        let a = PlannerTask(title: "A", tags: ["Rogers", "8FDE"])
        let b = PlannerTask(title: "B", tags: ["8FDE"])
        let c = PlannerTask(title: "C")
        let groups = TaskTagGroup.make([a, b, c], grouped: true)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.flatMap(\.tasks).map(\.id).count, 3)
        XCTAssertEqual(Set(groups.flatMap(\.tasks).map(\.id)), Set([a.id, b.id, c.id]))
        let filtered = TaskTagGroup.make([a, b, c], grouped: true, filter: .tag("8fde"))
        XCTAssertEqual(Set(filtered.flatMap(\.tasks).map(\.id)), Set([a.id, b.id]))
        XCTAssertEqual(TaskTagGroup.make([a, b, c], grouped: false, filter: .untagged).flatMap(\.tasks).map(\.id), [c.id])
        XCTAssertEqual(TaskTags.normalize([" #Rogers ", "rogers", "8FDE", " "]), ["Rogers", "8FDE"])
    }
    func testRefiningInboxItemPreservesIdentityAndExplicitChoices() throws {
        var original = PlannerTask(title: "So let's make a task for the proposal", tags: ["Rogers"], importance: true, urgency: false, remainingMinutes: 60, now: Date(timeIntervalSince1970: 1700000000))
        original.minimumBlockMinutes = 15; original.dependencies = ["discovery"]; original.resumeNote = "Keep the scope estimate"
        let batch = try ReviewedCapture(source: original.title, drafts: [CaptureDraft(title: "Review the Rogers proposal", tags: ["Rogers"]), CaptureDraft(title: "Update the 8FDE roadmap", tags: ["8FDE"])], settings: PlanningSettings(), replacing: original)
        let refined = batch.tasks[0]
        XCTAssertEqual(refined.id, original.id); XCTAssertEqual(refined.createdAt, original.createdAt)
        XCTAssertEqual(refined.revision, original.revision + 1); XCTAssertEqual(refined.state, .inbox)
        XCTAssertEqual(refined.remainingMinutes, 60); XCTAssertEqual(refined.minimumBlockMinutes, 15)
        XCTAssertEqual(refined.dependencies, original.dependencies); XCTAssertEqual(refined.resumeNote, original.resumeNote)
        XCTAssertEqual(refined.quadrant, original.quadrant)
        XCTAssertEqual(batch.capture.taskIDs, batch.tasks.map(\.id))
        XCTAssertEqual(batch.tasks[1].state, .inbox); XCTAssertEqual(batch.tasks[1].remainingMinutes, nil)
        original.state = .inProgress
        XCTAssertThrowsError(try ReviewedCapture(source: original.title, drafts: [CaptureDraft(title: "Replace")], settings: PlanningSettings(), replacing: original))
    }
    func testLiteLLMResponseValidation() throws {
        let tasks: [[String: Any]] = [["title": "Review the proposal for T One A", "notes": "Include eight F D E", "tags": ["rogers"]], ["title": "Update roadmap", "notes": "", "tags": ["8FDE"]]]
        let data = try Self.response(tasks)
        let drafts = try LiteLLMClient.parse(data, knownTags: ["Rogers"])
        XCTAssertEqual(drafts.map(\.title), ["Review the proposal for T1A", "Update roadmap"])
        XCTAssertEqual(drafts.first?.notes, "Include 8FDE"); XCTAssertEqual(drafts.first?.tags, ["Rogers"])
        XCTAssertThrowsError(try LiteLLMClient.parse(Self.response(tasks, reason: "length"), knownTags: []))
        XCTAssertThrowsError(try LiteLLMClient.parse(Self.response([["title": "", "notes": "", "tags": []]]), knownTags: []))
        XCTAssertThrowsError(try LiteLLMClient.parse(Data("{\"choices\":[]}".utf8), knownTags: []))
        XCTAssertThrowsError(try LiteLLMClient.parse(Self.response([]), knownTags: []))
        XCTAssertThrowsError(try LiteLLMConnection(baseURL: "http://proxy.example.com", model: "test").endpoint())
        XCTAssertEqual(try LiteLLMConnection(baseURL: "https://proxy.example.com/v1/", model: "test").endpoint().path, "/v1/chat/completions")
        XCTAssertEqual(try LiteLLMConnection(baseURL: "http://localhost:4000", model: "test").endpoint().path, "/chat/completions")
        XCTAssertThrowsError(try LiteLLMConnection(baseURL: "https://key@proxy.example.com", model: "test").endpoint())
    }
    func testClientContractAndHTTPFailures() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CaptureHTTPStub.self]
        let client = LiteLLMClient(session: URLSession(configuration: config))
        let source = "So let's create a task to review the proposal for T One A."
        var requestBody: [String: Any] = [:]
        CaptureHTTPStub.handle = { request in
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
            }
            requestBody = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
            return (200, try Self.response([["title": "Review the proposal for T1A", "notes": "", "tags": ["Rogers"]]]))
        }
        let drafts = try await client.process(source, knownTags: ["Rogers"], connection: LiteLLMConnection(baseURL: "https://proxy.example.com/v1", model: "chosen-alias"), apiKey: "synthetic-test-key")
        XCTAssertEqual(drafts.first?.title, "Review the proposal for T1A")
        XCTAssertEqual(requestBody["model"] as? String, "chosen-alias")
        let messages = requestBody["messages"] as! [[String: String]]
        let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        XCTAssertEqual(input["capture"] as? String, CaptureVocabulary.normalize(source))
        XCTAssertEqual(input["existing_project_product_tags"] as? [String], ["Rogers"])
        XCTAssertEqual(Set(input.keys), Set(["capture", "existing_project_product_tags"]))
        CaptureHTTPStub.handle = { _ in (401, Data("Do not expose a gateway response body".utf8)) }
        do {
            _ = try await client.process(source, knownTags: [], connection: LiteLLMConnection(baseURL: "https://proxy.example.com", model: "alias"), apiKey: "synthetic-test-key")
            XCTAssertTrue(false)
        } catch CaptureProcessingError.rejected(let status) { XCTAssertEqual(status, 401) }
        CaptureHTTPStub.handle = nil
    }
    static func response(_ tasks: [[String: Any]], reason: String = "stop") throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["tasks": tasks]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": reason]]])
    }
}

private final class CaptureHTTPStub: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
