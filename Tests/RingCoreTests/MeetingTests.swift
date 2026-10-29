import Foundation
import RingCore

struct MeetingTests {
    func testTranscriptLabelsAndBounds() throws {
        let data = Data(#"{"segments":[{"start":1,"end":4,"text":"Review T One A","speaker":"A"},{"start":4,"end":8,"text":"Вопросы для eight F D E","speaker":"B"}]}"#.utf8)
        let part = try MeetingProcessingClient.parseTranscript(data, partID: "part-002", offset: 1200, duration: 20)
        XCTAssertEqual(part.segments.map(\.speakerID), ["part-002:A", "part-002:B"])
        XCTAssertEqual(part.segments.first?.start, 1201); XCTAssertTrue(part.hasSpeakerLabels)
        XCTAssertEqual(part.segments.first?.text, "Review T1A")
        XCTAssertEqual(part.segments.last?.text, "Вопросы для 8FDE")
        let again = try MeetingProcessingClient.parseTranscript(data, partID: "part-002", offset: 1200, duration: 20)
        XCTAssertEqual(part.segments, again.segments)
        let other = try MeetingProcessingClient.parseTranscript(data, partID: "part-001", offset: 0, duration: 20)
        XCTAssertFalse(part.segments.first?.speakerID == other.segments.first?.speakerID)
        XCTAssertThrowsError(try MeetingProcessingClient.parseTranscript(data, partID: "part-001", offset: 0, duration: 1))
        XCTAssertThrowsError(try MeetingProcessingClient.parseTranscript(Data(#"{"segments":[{"start":-1,"end":5,"text":"bad"}]}"#.utf8), partID: "part", offset: 0, duration: 20))
        XCTAssertThrowsError(try MeetingProcessingClient.parseTranscript(Data(#"{"segments":[{"start":3,"end":2,"text":"bad"}]}"#.utf8), partID: "part", offset: 0, duration: 20))
        let unlabeled = try MeetingProcessingClient.parseTranscript(Data(#"{"text":"Hello from the meeting"}"#.utf8), partID: "part-001", offset: 0, duration: 10)
        XCTAssertFalse(unlabeled.hasSpeakerLabels); XCTAssertEqual(unlabeled.segments.first?.speakerID, "part-001:unassigned")
        XCTAssertThrowsError(try MeetingProcessingClient.parseTranscript(Data("{}".utf8), partID: "part", offset: 0, duration: 20))
        let silence = try MeetingProcessingClient.parseTranscript(Data(#"{"text":"","segments":[]}"#.utf8), partID: "part", offset: 0, duration: 20)
        XCTAssertTrue(silence.segments.isEmpty)
    }
    func testAnalysisRequiresEvidenceAndRealSpeakerIDs() throws {
        let segments = [MeetingSegment(id: "a", start: 0, end: 5, speakerID: "part-001:A", text: "I will send the T1A proposal Friday.")]
        func response(owner: String? = "part-001:A", evidence: [String] = ["a"], tasks: Bool = true) throws -> Data {
            var task: [String: Any] = ["title": "Send T One A proposal", "notes": "Include eight F D E", "tags": ["rogers"], "timing": "Friday", "evidence_segment_ids": evidence]
            task["speaker_id"] = owner ?? NSNull() as Any
            let payload: [String: Any] = ["summary": "Proposal reviewed", "decisions": [], "tasks": tasks ? [task] : []]
            let content = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        }
        let result = try MeetingProcessingClient.parseAnalysis(response(), segments: segments, knownTags: ["Rogers"])
        XCTAssertEqual(result.tasks.first?.title, "Send T1A proposal"); XCTAssertEqual(result.tasks.first?.notes, "Include 8FDE")
        XCTAssertEqual(result.tasks.first?.tags, ["Rogers"])
        XCTAssertThrowsError(try MeetingProcessingClient.parseAnalysis(response(owner: "invented-person"), segments: segments, knownTags: []))
        XCTAssertThrowsError(try MeetingProcessingClient.parseAnalysis(response(evidence: ["unknown"]), segments: segments, knownTags: []))
        XCTAssertThrowsError(try MeetingProcessingClient.parseAnalysis(response(evidence: []), segments: segments, knownTags: []))
        XCTAssertTrue(try MeetingProcessingClient.parseAnalysis(response(tasks: false), segments: segments, knownTags: []).tasks.isEmpty)
        XCTAssertTrue(MeetingProcessingClient.instructions.contains("untrusted source material"))
        XCTAssertTrue(MeetingProcessingClient.instructions.contains("Do not invent owners"))
    }
    func testReviewedImportKeepsOnlyApprovedEvidence() throws {
        var meeting = MeetingRecording(title: "Planning", language: .russian, source: .callAndMicrophone)
        meeting.segments = [MeetingSegment(id: "a", start: 4, end: 8, speakerID: "part-001:A", text: "Я отправлю предложение."), MeetingSegment(id: "private", start: 10, end: 20, speakerID: "part-001:B", text: "PRIVATE UNRELATED CONVERSATION")]
        meeting.speakerNames["part-001:A"] = "Oleg"
        var excluded = MeetingTaskSuggestion(title: "Ignored"); excluded.included = false
        meeting.suggestions = [MeetingTaskSuggestion(title: " Send proposal ", tags: ["rogers"], speakerID: "part-001:A", timing: "Friday", evidenceIDs: ["a"]), excluded]
        let first = try MeetingTaskImport(meeting: meeting, settings: PlanningSettings(), knownTags: ["Rogers"])
        let retry = try MeetingTaskImport(meeting: meeting, settings: PlanningSettings(), knownTags: ["Rogers"])
        XCTAssertEqual(first.tasks.map(\.id), retry.tasks.map(\.id)); XCTAssertEqual(first.tasks.count, 1)
        XCTAssertEqual(first.tasks[0].state, .inbox); XCTAssertEqual(first.tasks[0].title, "Send proposal")
        XCTAssertTrue(first.tasks[0].notes.contains("Owner: Oleg")); XCTAssertTrue(first.tasks[0].notes.contains("[00:04]"))
        XCTAssertFalse(first.capture.text.contains("PRIVATE")); XCTAssertFalse(first.tasks[0].notes.contains("PRIVATE"))
        XCTAssertEqual(first.tasks[0].sourceCaptureID, first.capture.id); XCTAssertEqual(first.tasks[0].tags, ["Rogers"])
        XCTAssertEqual(first.tasks[0].remainingMinutes, nil); XCTAssertEqual(first.tasks[0].importance, nil)
        meeting.suggestions[0].savedTaskID = first.tasks[0].id
        XCTAssertThrowsError(try MeetingTaskImport(meeting: meeting, settings: PlanningSettings(), knownTags: []))
    }
    func testRecoveryAndImportReceiptStayOutsideTaskHistory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try MeetingRepository(root: base.appendingPathComponent("Meetings"))
        var meeting = MeetingRecording(title: "Interrupted recording", language: .english, source: .microphone)
        meeting.suggestions = [MeetingTaskSuggestion(title: "Review plan")]
        let receipt = try MeetingTaskImport(meeting: meeting, settings: PlanningSettings(), knownTags: [], now: Date(timeIntervalSince1970: 1700000000))
        meeting.pendingTaskImport = receipt
        try repository.save(meeting)
        let restarted = try repository.load()
        XCTAssertEqual(restarted.first?.state, .interrupted)
        XCTAssertTrue(restarted.first?.lastError?.contains("interrupted") == true)
        XCTAssertEqual(restarted.first?.pendingTaskImport, receipt)
        let folder = try repository.folder(meeting.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("meeting.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".git").path))
        XCTAssertThrowsError(try repository.folder("../Data"))
        let linkID = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: repository.root.appendingPathComponent(linkID), withDestinationURL: base)
        XCTAssertThrowsError(try repository.folder(linkID))
    }
    func testCatalogAndEndpointCapabilities() throws {
        let data = Data(#"{"data":[{"id":"chat-model"},{"id":"audio-model","model_info":{"mode":"audio_transcription"},"litellm_params":{"api_key":"NEVER DISPLAY THIS"}},{"id":"gpt-transcribe-diarize"}]}"#.utf8)
        let models = try MeetingProcessingClient.parseModels(data)
        XCTAssertEqual(models.count, 3); XCTAssertFalse(models[0].isAudioCandidate)
        XCTAssertTrue(models[1].isAudioCandidate); XCTAssertEqual(models[1].mode, "audio_transcription")
        XCTAssertTrue(models[2].isDiarizationCandidate)
        XCTAssertEqual(try MeetingProcessingClient.transcriptionURL(baseURL: "https://gateway.example/api/v1", model: "audio").path, "/api/v1/audio/transcriptions")
        XCTAssertThrowsError(try MeetingProcessingClient.transcriptionURL(baseURL: "https://gateway.example/v1", model: ""))
        XCTAssertThrowsError(try MeetingProcessingClient.transcriptionURL(baseURL: "http://gateway.example/v1", model: "audio"))
        let segments = (0..<5).map { MeetingSegment(start: Double($0), end: Double($0 + 1), speakerID: "A", text: String(repeating: "a", count: 6000)) }
        let batches = MeetingProcessingClient.batches(segments)
        XCTAssertEqual(batches.count, 5); XCTAssertEqual(batches.flatMap { $0 }.map(\.id), segments.map(\.id))
        XCTAssertEqual(MeetingLanguage.russian.locale, "ru-RU"); XCTAssertEqual(MeetingLanguage.automatic.code, nil)
    }
    func testAudioHTTPContractAndPartialFailure() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("SYNTHETIC AUDIO FIXTURE".utf8).write(to: file)
        var requests: [URLRequest] = []
        var lastBody = Data()
        MeetingHTTPStub.handle = { request in
            requests.append(request)
            if let body = request.httpBody { lastBody = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); var data = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }; lastBody = data
            }
            if request.url?.path.hasSuffix("/models") == true { return (200, Data(#"{"data":[{"id":"audio-model"},{"id":"chat-model"}]}"#.utf8)) }
            if request.url?.path.hasSuffix("/model/info") == true { return (403, Data()) }
            return (200, Data(#"{"segments":[{"start":0,"end":1,"text":"Review plan","speaker":"A"}]}"#.utf8))
        }
        let connection = LiteLLMConnection(baseURL: "https://gateway.example/api/v1", model: "chat-model")
        let models = try await client.models(connection: connection, apiKey: "fixture-key")
        XCTAssertEqual(models.count, 2)
        let transcript = try await client.transcribe(file: file, partID: "part-001", offset: 0, duration: 3, language: .russian, speakerLabels: true, connection: connection, audioModel: "diarization-model", apiKey: "fixture-key")
        XCTAssertTrue(transcript.hasSpeakerLabels)
        let request = requests.last!, body = String(decoding: lastBody, as: UTF8.self)
        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions"); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertTrue(body.contains("diarization-model")); XCTAssertTrue(body.contains("diarized_json")); XCTAssertTrue(body.contains("chunking_strategy")); XCTAssertTrue(body.contains("\r\nru\r\n")); XCTAssertTrue(body.contains("SYNTHETIC AUDIO FIXTURE"))
        MeetingHTTPStub.handle = { _ in (429, Data()) }
        do { _ = try await client.transcribe(file: file, partID: "part", offset: 0, duration: 3, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture-key"); XCTAssertTrue(false) }
        catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
    }
}
private final class MeetingHTTPStub: URLProtocol {
    static var handle: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handle!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension MeetingTests {
    func testTranscriptionModelContracts() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config), sleep: { _ in })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }; try Data("SYNTHETIC".utf8).write(to: file)
        var body = Data()
        MeetingHTTPStub.handle = { request in
            body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
            }
            return (200, Data(#"{"text":"Synthetic speech","segments":[{"start":0,"end":1,"text":"Synthetic speech"}]}"#.utf8))
        }
        for alias in ["whisper-1", "openai/whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            let result = try await client.transcribe(file: file, partID: "fixture", offset: 0, duration: 1, language: .automatic,
                speakerLabels: true, connection: .init(baseURL: "https://gateway.example/v1", model: "text"), audioModel: alias, apiKey: "fixture")
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(text.contains("diarized_json")); XCTAssertFalse(text.contains("chunking_strategy")); XCTAssertFalse(result.hasSpeakerLabels)
            if alias.contains("whisper") { XCTAssertTrue(text.contains("verbose_json")); XCTAssertTrue(text.contains("timestamp_granularities[]")) }
            else { XCTAssertTrue(text.contains("\r\njson\r\n")); XCTAssertFalse(text.contains("verbose_json")) }
        }
        let diarization = MeetingTranscriptionOptions.resolve(model: "gpt-4o-transcribe-diarize", speakerLabels: false)
        XCTAssertTrue(diarization.automaticChunking); XCTAssertEqual(diarization.responseFormat, "json")
        XCTAssertFalse(MeetingTranscriptionOptions.resolve(model: "whisper-1", speakerLabels: true).speakerSeparation)
        let padding = Data(#"{"text":"Do not restore padded text","segments":[{"start":179,"end":190,"text":"Valid ending"},{"start":181,"end":190,"text":"Padding outside audio"}]}"#.utf8)
        let bounded = try MeetingProcessingClient.parseTranscript(padding, partID: "clip", offset: 300, duration: 180, allowTrailingPadding: true)
        XCTAssertEqual(bounded.segments.count, 1); XCTAssertEqual(bounded.segments[0].end, 480)
        XCTAssertThrowsError(try MeetingProcessingClient.parseTranscript(padding, partID: "clip", offset: 300, duration: 180))
        var calls = 0
        MeetingHTTPStub.handle = { _ in calls += 1; return (200, Data(#"{"segments":[{"start":0,"end":90000,"text":"PRIVATE RESPONSE"}]}"#.utf8)) }
        do {
            _ = try await client.transcribe(file: file, partID: "fixture", offset: 0, duration: 1, language: .automatic,
                speakerLabels: true, connection: .init(baseURL: "https://gateway.example/v1", model: "text"), audioModel: "whisper-1", apiKey: "fixture")
            XCTAssertTrue(false)
        } catch let error as MeetingTranscriptResponseError {
            XCTAssertEqual(calls, 3); XCTAssertTrue(error.localizedDescription.contains("90000.0")); XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
    }
    func testLongMeetingHTTPRetriesResumeAndCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config), sleep: { _ in })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("SYNTHETIC AUDIO".utf8).write(to: file)
        let connection = LiteLLMConnection(baseURL: "https://gateway.example/v1", model: "text")
        var requests = 0
        MeetingHTTPStub.handle = { _ in requests += 1; return requests == 1 ? (504, Data()) : (200, Data(#"{"segments":[{"start":0,"end":1,"text":"Synthetic speech","speaker":"A"}]}"#.utf8)) }
        let recovered = try await client.transcribe(file: file, partID: "part", offset: 0, duration: 3, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture")
        XCTAssertEqual(requests, 2); XCTAssertEqual(recovered.segments.count, 1)
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (504, Data()) }
        do {
            _ = try await client.transcribe(file: file, partID: "part", offset: 0, duration: 180, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture", timeoutAttempts: 1)
            XCTAssertTrue(false)
        } catch { XCTAssertTrue(MeetingRetryPolicy.isTimeout(error)); XCTAssertEqual(requests, 1) }
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (404, Data()) }
        do {
            _ = try await client.transcribe(file: file, partID: "part", offset: 0, duration: 3, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture")
            XCTAssertTrue(false)
        } catch { XCTAssertEqual(requests, 1) }
        // Process an hour, persist at an interruption, then finish only the missing audio.
        var record = MeetingRecording(title: "Hour fixture", language: .automatic, source: .call)
        requests = 0
        MeetingHTTPStub.handle = { _ in requests += 1; return (200, Data(#"{"segments":[{"start":0,"end":180,"text":"Synthetic speech","speaker":"A"}]}"#.utf8)) }
        let chunks = MeetingChunkPlanner.pending(totalFrames: 3600 * 16000, completed: [])
        for chunk in chunks.prefix(7) {
            let result = try await client.transcribe(file: file, partID: chunk.id, offset: chunk.offset, duration: chunk.duration, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture")
            record.segments += result.segments; record.completedAudioParts.append(chunk.id)
        }
        let encoded = try JSONEncoder().encode(record); record = try JSONDecoder().decode(MeetingRecording.self, from: encoded)
        for chunk in MeetingChunkPlanner.pending(totalFrames: 3600 * 16000, completed: record.completedAudioParts) {
            let result = try await client.transcribe(file: file, partID: chunk.id, offset: chunk.offset, duration: chunk.duration, language: .automatic, speakerLabels: true, connection: connection, audioModel: "audio", apiKey: "fixture")
            record.segments += result.segments; record.completedAudioParts.append(chunk.id)
        }
        XCTAssertEqual(requests, 20); XCTAssertEqual(record.segments.last?.end, 3600)
        XCTAssertEqual(Set(record.segments.map(\.id)).count, 20)
        let cancelling = MeetingProcessingClient(session: URLSession(configuration: config), sleep: { _ in throw CancellationError() })
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (503, Data()) }
        do {
            _ = try await cancelling.transcribe(file: file, partID: "part", offset: 0, duration: 3, language: .english, speakerLabels: false, connection: connection, audioModel: "audio", apiKey: "fixture")
            XCTAssertTrue(false)
        } catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(requests, 1) }
    }
    func testGatewayFailuresIdentifyStageAndModelWithoutEchoingPayloads() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config))
        MeetingHTTPStub.handle = { _ in (404, Data(#"{"error":{"message":"SENSITIVE SERVER ECHO"}}"#.utf8)) }
        let connection = LiteLLMConnection(baseURL: "https://gateway.example/api/v1", model: "unavailable-text")
        let segment = MeetingSegment(id: "s", start: 0, end: 1, speakerID: "A", text: "Synthetic fixture")
        let meeting = MeetingRecording(title: "Fixture", language: .english, source: .call)
        do {
            _ = try await client.analyze([segment], meeting: meeting, knownTags: [], connection: connection, apiKey: "SYNTHETIC-KEY")
            XCTAssertTrue(false)
        } catch let failure as MeetingGatewayFailure {
            XCTAssertEqual(failure.stage, .analysis); XCTAssertEqual(failure.model, "unavailable-text")
            XCTAssertEqual(failure.path, "/api/v1/chat/completions"); XCTAssertEqual(failure.status, 404)
            XCTAssertTrue(failure.localizedDescription.contains("transcript is saved"))
            XCTAssertTrue(failure.localizedDescription.contains("without uploading audio"))
            XCTAssertFalse(failure.localizedDescription.contains("SENSITIVE SERVER ECHO"))
            XCTAssertFalse(failure.localizedDescription.contains("SYNTHETIC-KEY"))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("SYNTHETIC AUDIO".utf8).write(to: file)
        do {
            _ = try await client.transcribe(file: file, partID: "part", offset: 0, duration: 1, language: .english, speakerLabels: true, connection: connection, audioModel: "unavailable-audio", apiKey: "SYNTHETIC-KEY")
            XCTAssertTrue(false)
        } catch let failure as MeetingGatewayFailure {
            XCTAssertEqual(failure.stage, .transcription); XCTAssertEqual(failure.model, "unavailable-audio")
            XCTAssertEqual(failure.path, "/api/v1/audio/transcriptions")
            XCTAssertTrue(failure.localizedDescription.contains("recording is preserved"))
            XCTAssertFalse(failure.localizedDescription.contains("text-model alias"))
        }
    }
    func testTopicAnalysisHTTPContractIncludesRealTimes() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config))
        let segment = MeetingSegment(id: "passage", start: 65, end: 83, speakerID: "A", text: "Обсудим план запуска продукта.")
        var requestBytes = Data()
        let response = try MeetingNavigationTests().response(topics: [["title":"Запуск продукта", "summary":"Обсуждение плана", "evidence_segment_ids":["e1"]]])
        MeetingHTTPStub.handle = { request in
            requestBytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; requestBytes.append(buffer, count: count) }
            }
            return (200, response)
        }
        let meeting = MeetingRecording(title: "Product launch", language: .russian, source: .call)
        let result = try await client.analyze([segment], meeting: meeting, knownTags: [], connection: .init(baseURL: "https://gateway.example/v1", model: "text-model"), apiKey: "synthetic")
        let body = try JSONSerialization.jsonObject(with: requestBytes) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        let supplied = (input["segments"] as! [[String: Any]])[0]
        XCTAssertEqual(supplied["start"] as? Double, 65); XCTAssertEqual(supplied["end"] as? Double, 83)
        XCTAssertEqual(supplied["id"] as? String, "e1"); XCTAssertEqual(supplied["speaker_id"] as? String, "p1")
        XCTAssertTrue(messages[0]["content"]!.contains("do not invent timestamps"))
        XCTAssertEqual(MeetingNavigation.topics(result.topics, segments: [segment]).first?.start, 65)
        XCTAssertEqual(result.tasks.count, 0)
    }
    func testAnalysisRecoversInvalidRepliesAndRestoresDurableEvidence() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeetingHTTPStub.self]
        let client = MeetingProcessingClient(session: URLSession(configuration: config), sleep: { _ in })
        let segments = [MeetingSegment(id: String(repeating: "a", count: 64), start: 65, end: 83, speakerID: "stt-0-2880000:A", text: "I will send the T1A proposal."),
                        MeetingSegment(id: String(repeating: "b", count: 64), start: 83, end: 90, speakerID: "stt-0-2880000:B", text: "Agreed."),
                        MeetingSegment(id: String(repeating: "c", count: 64), start: 90, end: 95, speakerID: "stt-0-2880000:A", text: "Friday.")]
        let task: [String: Any] = ["title":"Send proposal", "notes":"", "tags":["T1A"], "timing":"Friday", "speaker_id":"p1", "evidence_segment_ids":["e1","e3"]]
        let topic: [String: Any] = ["title":"Proposal", "summary":"", "evidence_segment_ids":["e1","e2","e3"]]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["summary":"Plan", "decisions":[], "tasks":[task], "topics":[topic]]), as: UTF8.self)
        let good = try JSONSerialization.data(withJSONObject: ["choices":[["finish_reason":"stop", "message":["content":content]]]])
        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"PRIVATE INCOMPLETE OUTPUT"}}]}"#.utf8)
        var requests = 0
        MeetingHTTPStub.handle = { _ in requests += 1; return (200, requests == 1 ? truncated : good) }
        let connection = LiteLLMConnection(baseURL: "https://gateway.example/v1", model: "text")
        let meeting = MeetingRecording(title: "Fixture", language: .english, source: .call)
        let result = try await client.analyze(segments, meeting: meeting, knownTags: ["T1A"], connection: connection, apiKey: "fixture")
        XCTAssertEqual(requests, 2); XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].evidenceIDs, [segments[0].id, segments[2].id]); XCTAssertEqual(result.tasks[0].speakerID, segments[0].speakerID)
        XCTAssertEqual(result.topics[0].evidenceIDs, segments.map(\.id))
        XCTAssertEqual(result.topics[0].id, MeetingTopic(title: "Proposal", evidenceIDs: segments.map(\.id)).id)
        XCTAssertEqual(MeetingNavigation.topics(result.topics, segments: segments).first?.start, 65)
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (200, truncated) }
        do {
            _ = try await client.analyze(segments, meeting: meeting, knownTags: [], connection: connection, apiKey: "fixture")
            XCTAssertTrue(false)
        } catch let error as MeetingAnalysisResponseError {
            XCTAssertEqual(requests, 3); XCTAssertEqual(error.reason, .truncated)
            XCTAssertTrue(error.localizedDescription.contains("output limit")); XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
        let refusal = Data(#"{"choices":[{"finish_reason":"stop","message":{"refusal":"PRIVATE REFUSAL"}}]}"#.utf8)
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (200, refusal) }
        do {
            _ = try await client.analyze(segments, meeting: meeting, knownTags: [], connection: connection, apiKey: "fixture")
            XCTAssertTrue(false)
        } catch let error as MeetingAnalysisResponseError { XCTAssertEqual(requests, 1); XCTAssertEqual(error.reason, .refused) }
        let cancelling = MeetingProcessingClient(session: URLSession(configuration: config), sleep: { _ in throw CancellationError() })
        requests = 0; MeetingHTTPStub.handle = { _ in requests += 1; return (200, truncated) }
        do {
            _ = try await cancelling.analyze(segments, meeting: meeting, knownTags: [], connection: connection, apiKey: "fixture")
            XCTAssertTrue(false)
        } catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(requests, 1) }
    }
}
