import Foundation
import RingCore

private final class LibraryHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw LibraryError.invalid("Unmocked Library network request") }
            let (status,headers,data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class LibraryServiceTests {
    func testAreaClassificationAndMixedCapture() async throws {
        LibraryHTTPStub.handler = { _ in (200, [:], try self.chat(["kind":"Task", "title":"Buy provisions", "area":"Personal", "tags":["Fellowship", "Work"]])) }
        let item = InboxItem(text: "Buy provisions for second breakfast")
        let classified = try await LibraryAIClient(http: http()).classifyInbox(item, extractedText: "", knownTags: [], connection: connection, key: "synthetic-key")
        XCTAssertEqual(classified.tags, ["Fellowship", "Personal"])
        XCTAssertEqual(item.text, "Buy provisions for second breakfast")
        let data = try chat(["tasks": [["title":"Buy mushrooms", "notes":"For Bilbo", "area":"Personal", "tags":["Shire"]], ["title":"Review proposal", "notes":"", "area":"Work", "tags":["Fellowship"]]]])
        let drafts = try LiteLLMClient.parse(data, knownTags: [])
        XCTAssertEqual(drafts[0].tags, ["Shire", "Personal"])
        XCTAssertEqual(drafts[1].tags, ["Fellowship", "Work"])
        XCTAssertTrue(LiteLLMClient.instructions.contains("Classify each task independently"))
        XCTAssertThrowsError(try LiteLLMClient.parse(chat(["tasks": [["title":"Invalid area", "notes":"", "area":"Other", "tags":[]]]]), knownTags: []))
    }

    func testTaskCaptureSendsEveryImageAndReturnsSearchTags() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LibraryHTTPStub.self]
        var receivedImages = 0
        LibraryHTTPStub.handler = { request in
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let content = messages[1]["content"] as! [[String: Any]]
            receivedImages = content.filter { $0["type"] as? String == "image_url" }.count
            return (200, [:], try self.chat(["tasks": [["title": "Review the route", "notes": "Compare both maps", "tags": ["Fellowship", "Cartography"]]]]))
        }
        let images = [LibraryAIImage(id: "one", bytes: Data([1])), LibraryAIImage(id: "two", bytes: Data([2]))]
        let drafts = try await LiteLLMClient(session: URLSession(configuration: config)).process("", images: images, knownTags: ["Fellowship"], connection: connection, apiKey: "synthetic-key")
        XCTAssertEqual(receivedImages, 2); XCTAssertEqual(drafts.first?.tags, ["Fellowship", "Cartography"])
    }
    func testInboxClassificationHasItsOwnValidatedContract() async throws {
        let item = InboxItem(text: "Reusable map https://example.com/map")
        LibraryHTTPStub.handler = { _ in (200, [:], try self.chat(["kind":"Note", "title":"Map for T One A and eight F D E", "tags":["Fellowship"]])) }
        let classified = try await LibraryAIClient(http: http()).classifyInbox(item, extractedText: "", knownTags: [], connection: connection, key: "synthetic-key")
        XCTAssertEqual(classified.kind, .note); XCTAssertEqual(classified.title, "Map for T1A and 8FDE"); XCTAssertEqual(item.text, "Reusable map https://example.com/map")
        LibraryHTTPStub.handler = { _ in (200, [:], try self.chat(["kind":"Move automatically", "title":"Invalid", "tags":[]])) }
        do { _ = try await LibraryAIClient(http: http()).classifyInbox(item, extractedText: "", knownTags: [], connection: connection, key: "synthetic-key"); XCTAssertTrue(false) } catch {}
        LibraryHTTPStub.handler = { _ in (429, ["Retry-After":"20"], Data()) }
        do { _ = try await LibraryAIClient(http: http()).classifyInbox(item, extractedText: "", knownTags: [], connection: connection, key: "synthetic-key"); XCTAssertTrue(false) }
        catch let failure as LibraryHTTPFailure { XCTAssertTrue(failure.transient); XCTAssertEqual(failure.retryAfter, 20) }
    }
    private func http() -> LibraryHTTP { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LibraryHTTPStub.self]; return LibraryHTTP(session: URLSession(configuration: config)) }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func chat(_ fields: [String: Any]) throws -> Data { try data(["choices": [["finish_reason": "stop", "message": ["content": String(decoding: data(fields), as: UTF8.self)]]]]) }
    private let connection = LiteLLMConnection(baseURL: "https://synthetic-gateway.invalid/gateway/api/v1", model: "synthetic-library-model")
    func testLibraryContractStoresLongSourcesAndRejectsMalformedOrganization() async throws {
        let note = LibraryNote(body: String(repeating: "Exact skill text. ", count: 700))
        var sawLongSource = false
        LibraryHTTPStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            }
            sawLongSource = bytes.count > 6000
            return (200, [:], try self.chat(["title":"A reusable skill","summary":"A calm reference","tags":["Fellowship"],"kinds":["Skill"],"imageDescriptions":[:],"relatedNoteIDs":[]]))
        }
        let result = try await LibraryAIClient(http: http()).organize(note, extractedText: "", related: [], images: [], connection: connection, key: "synthetic-key")
        XCTAssertTrue(sawLongSource); XCTAssertEqual(result.title, "A reusable skill"); XCTAssertEqual(note.body.count, 12600)
        LibraryHTTPStub.handler = { _ in (200, [:], try self.chat(["title":"Invalid", "summary":"", "tags":[], "kinds":["Skill"], "imageDescriptions":[:], "relatedNoteIDs":["untrusted-id"]])) }
        do { _ = try await LibraryAIClient(http: http()).organize(note, extractedText: "", related: [], images: [], connection: connection, key: "synthetic-key"); XCTAssertTrue(false) } catch { XCTAssertTrue(error is LibraryError) }
    }
    func testEmbeddingAndVisionCapabilitiesRequireValidSeparateResponses() async throws {
        var paths: [String] = []
        LibraryHTTPStub.handler = { request in paths.append(request.url!.path); return (200, [:], try self.data(["data":[["embedding":[0.2,0.4,0.6]]]])) }
        let client = LibraryAIClient(http: http())
        let vector = try await client.embedding("Synthetic", connection: connection, key: "synthetic-key")
        XCTAssertEqual(vector.count, 3); XCTAssertEqual(paths, ["/gateway/api/v1/embeddings"])
        do { _ = try await client.embedding("Synthetic", connection: connection, key: "synthetic-key", expectedDimensions: 4); XCTAssertTrue(false) } catch {}
        var index = 0
        LibraryHTTPStub.handler = { _ in defer { index += 1 }; return (200, [:], try self.chat(["color":index == 0 ? "red" : "blue"])) }
        let swatches = [LibraryAIImage(id: "red", bytes: Data([1])), LibraryAIImage(id: "blue", bytes: Data([2]))]
        try await client.verifyVision(images: swatches, connection: connection, key: "synthetic-key")
        XCTAssertEqual(index, 2)
        LibraryHTTPStub.handler = { _ in (200, [:], try self.chat(["color":"unknown"])) }
        do { try await client.verifyVision(images: swatches, connection: connection, key: "synthetic-key"); XCTAssertTrue(false) } catch {}
    }
    func testPrivateVisibilityRateLimitsAndRedirectFailuresRemainExplicit() async throws {
        let transport = http()
        LibraryHTTPStub.handler = { _ in (200, [:], try self.data(["private":false, "archived":false])) }
        do { try await LibraryRemoteBackup.verifyPrivate("https://github.com/synthetic/private.git", token: "synthetic-token", http: transport); XCTAssertTrue(false) } catch {}
        LibraryHTTPStub.handler = { _ in (200, [:], try self.data(["private":true, "archived":false])) }
        try await LibraryRemoteBackup.verifyPrivate("https://github.com/synthetic/private.git", token: "synthetic-token", http: transport)
        LibraryHTTPStub.handler = { _ in (429, ["Retry-After":"25"], Data()) }
        do { _ = try await LibraryAIClient(http: transport).embedding("Test", connection: connection, key: "synthetic-key"); XCTAssertTrue(false) }
        catch let error as LibraryHTTPFailure { XCTAssertEqual(error.status, 429); XCTAssertEqual(error.retryAfter, 25); XCTAssertTrue(error.transient) }
        LibraryHTTPStub.handler = { _ in (302, ["Location":"https://another.invalid"], Data()) }
        do { _ = try await transport.data(URLRequest(url: URL(string:"https://synthetic-gateway.invalid")!)); XCTAssertTrue(false) }
        catch let error as LibraryHTTPFailure { XCTAssertEqual(error.status, 302); XCTAssertFalse(error.transient) }
    }
    func testTelegramHTTPNeverAcknowledgesBadAttachmentBytes() async throws {
        let bytes = Data("actual bytes".utf8), hash = LibraryHash.digest(Data("expected bytes".utf8))
        let file = LibraryTelegramFile(hash: hash, byteCount: bytes.count, name: "image.png", fileExtension: "png")
        let capture = LibraryTelegramCapture(id: LibraryHash.digest(Data("capture".utf8)), threadID: LibraryHash.digest(Data("thread".utf8)), items: [.init(id: "source", text: "Exact", capturedAt: Date(), files: [file])])
        var acknowledgements = 0
        LibraryHTTPStub.handler = { request in if request.url!.path.hasSuffix("/ack") { acknowledgements += 1 }; return (200, [:], bytes) }
        let client = try LibraryTelegramClient(endpoint: "https://synthetic-inbox.invalid", token: "synthetic-client-token", http: http())
        do { _ = try await client.attachments(capture); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertThrowsError(try LibraryTelegramClient(endpoint: "https://token@inbox.invalid", token: "synthetic"))
    }
}
