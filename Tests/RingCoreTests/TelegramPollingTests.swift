import Foundation
import RingCore

private final class TelegramHTTPStub: URLProtocol {
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
final class TelegramPollingTests {
    let token = "123456789:synthetic_bot_token_0123456789"
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func update(id: Int64 = 10, sender: Int64 = 42, chat: Int64 = 42, type: String = "private", text: String = "Buy mushrooms for Bilbo", voice: Bool = false) throws -> TelegramUpdate {
        var message: [String: Any] = ["message_id":id, "date":1794492000, "from":["id":sender, "is_bot":false], "chat":["id":chat, "type":type]]
        if voice { message["voice"] = ["file_id":"synthetic-voice", "file_size":3, "duration":10] } else { message["text"] = text }
        return try JSONDecoder().decode(TelegramUpdate.self, from: data(["update_id":id, "message":message]))
    }
    func client() throws -> TelegramBotClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TelegramHTTPStub.self]
        return try TelegramBotClient(token: token, session: URLSession(configuration: config))
    }
    func body(_ request: URLRequest) throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf:buffer.prefix(n)) }
        }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    func testPairingChallengeRejectsOtherChatsAndExpiredCodes() throws {
        let now = Date(), code = String(repeating:"a",count:32)
        XCTAssertTrue(TelegramPairing.matches(try update(text:"/pair " + code).message!,code:code,expires:now.addingTimeInterval(600),now:now))
        XCTAssertFalse(TelegramPairing.matches(try update(chat:-1,type:"group",text:"/pair " + code).message!,code:code,expires:now.addingTimeInterval(600),now:now))
        XCTAssertFalse(TelegramPairing.matches(try update(sender:7,text:"/pair " + code).message!,code:code,expires:now.addingTimeInterval(600),now:now))
        XCTAssertFalse(TelegramPairing.matches(try update(text:"/pair " + code).message!,code:code,expires:now.addingTimeInterval(-1),now:now))
        XCTAssertFalse(TelegramPairing.matches(try update(text:"/pair wrong").message!,code:code,expires:now.addingTimeInterval(600),now:now))
        var state = TelegramPollingState(); state.ownerID = 42
        for id in 0..<1000 { try state.receive([update(id:Int64(id))]) }
        let offset = state.offset
        XCTAssertThrowsError(try state.receive([update(id:1000)]))
        XCTAssertEqual(state.jobs.count,1000); XCTAssertEqual(state.offset,offset)
    }
    func testOwnerOnlyCursorAndReplay() throws {
        var state = TelegramPollingState()
        try state.receive([update(id:1)])
        XCTAssertTrue(state.jobs.isEmpty); XCTAssertEqual(state.offset,2)
        state.ownerID = 42
        let accepted = try update(id:5)
        try state.receive([update(id:2,sender:7), update(id:3,chat:-9,type:"group"), update(id:4,sender:7,chat:42), accepted])
        XCTAssertEqual(state.jobs.map(\.id),[5]); XCTAssertEqual(state.offset,6)
        try state.receive([accepted]); XCTAssertEqual(state.jobs.count,1)
        let encoded = try JSONEncoder().encode(state), restarted = try JSONDecoder().decode(TelegramPollingState.self, from: encoded)
        XCTAssertEqual(restarted.ownerID,42); XCTAssertEqual(restarted.offset,6); XCTAssertEqual(restarted.jobs.count,1)
        var settings = TelegramPollingSettings(); XCTAssertTrue(settings.isValid)
        settings.eventAlerts = true; settings.interval = 60; XCTAssertFalse(settings.isValid)
        settings.interval = 15; XCTAssertTrue(settings.isValid)
    }
    func testImportIdempotenceAndSourceSurvival() throws {
        let (base, repo) = try LibraryTests().workspace(); defer { try? FileManager.default.removeItem(at:base) }
        let event = try update(), first = try TelegramCapture.save(event, botID:1, ownerID:42, attachment:nil, repository:repo)
        XCTAssertEqual(first.text,"Buy mushrooms for Bilbo")
        XCTAssertThrowsError(try TelegramCapture.save(update(id:11,sender:7),botID:1,ownerID:42,attachment:nil,repository:repo))
        var edited = first; edited.titleOverride = "Buy tea"; edited.revision += 1
        try repo.saveInbox(edited, expectedRevision:first.revision)
        let replay = try TelegramCapture.save(event,botID:1,ownerID:42,attachment:nil,repository:repo)
        XCTAssertEqual(replay.titleOverride,"Buy tea"); XCTAssertEqual(try repo.loadInbox().count,1)
        let voice = try update(id:12,voice:true)
        let pending = try TelegramCapture.save(voice,botID:1,ownerID:42,attachment:nil,repository:repo)
        XCTAssertTrue(pending.attachments.isEmpty)
        let recoveredAsset = try LibraryAttachments.prepare(data:Data([1]),name:"voice.ogg",extension:"ogg",localState:repo.localState)
        let recovered = try TelegramCapture.save(voice,botID:1,ownerID:42,attachment:recoveredAsset,repository:repo)
        XCTAssertEqual(recovered.attachments.count,1)
        XCTAssertFalse(TelegramCapture.identity(botID:1,updateID:10) == TelegramCapture.identity(botID:2,updateID:10))
        XCTAssertTrue(UUID(uuidString:first.id) != nil)
    }
    func testAudioSplitsAndRecoveryRetainOriginals() throws {
        let (base, repo) = try LibraryTests().workspace(); defer { try? FileManager.default.removeItem(at:base) }
        let asset = try LibraryAttachments.prepare(data:Data([1,2,3]),name:"voice.ogg",extension:"ogg",localState:repo.localState)
        let event = try update(voice:true), original = try TelegramCapture.save(event,botID:1,ownerID:42,attachment:asset,repository:repo)
        XCTAssertTrue(original.awaitingTranscription)
        var pendingTask = TaskTriage.proposing(original.task(settings:PlanningSettings()),quadrant:.schedule)
        pendingTask.remainingMinutes = 15; pendingTask.minimumBlockMinutes = 15
        XCTAssertThrowsError(try repo.routeInbox(original,as:.task,task:pendingTask,settings:PlanningSettings()))
        let drafts = [TelegramDraft(CaptureDraft(title:"Buy mushrooms",tags:["Shire","Personal"])), TelegramDraft(CaptureDraft(title:"Review the map",tags:["Fellowship","Work"]))]
        let all = try TelegramCapture.finishAudio(update:event,botID:1,transcript:"Купить грибы. Review the map.",drafts:drafts,repository:repo)
        XCTAssertEqual(all.count,3); XCTAssertTrue(all[0].archived); XCTAssertEqual(all[0].text,"Voice or audio recording")
        XCTAssertEqual(all[0].content,"Купить грибы. Review the map.")
        XCTAssertEqual(all[1].tags,["Shire","Personal"]); XCTAssertEqual(all[2].tags,["Fellowship","Work"])
        XCTAssertEqual(try repo.load(PlannerTask.self,directory:"tasks").count,0)
        XCTAssertEqual(try repo.load(Capture.self,directory:"captures").count,0)
        XCTAssertEqual(try Data(contentsOf:repo.validatedURL(asset.attachment.path)),Data([1,2,3]))
        let replay = try TelegramCapture.finishAudio(update:event,botID:1,transcript:"Купить грибы. Review the map.",drafts:drafts,repository:repo)
        XCTAssertEqual(replay.count,1); XCTAssertEqual(try repo.loadInbox().count,3)
        var child = try repo.loadInbox().first { $0.id == all[1].id }!; child.archived = true; child.revision += 1
        try repo.saveInbox(child,expectedRevision:child.revision-1)
        _ = try TelegramCapture.finishAudio(update:event,botID:1,transcript:"Купить грибы. Review the map.",drafts:drafts,repository:repo)
        XCTAssertTrue(try repo.loadInbox().first { $0.id == child.id }!.archived)
        let archive = base.appendingPathComponent("Archive"); try LibraryArchive.create(repository:repo,destination:archive)
        let restored = try LibraryArchive.restoreArchive(archive,into:base.appendingPathComponent("Restored"))
        let restoredRepo = try DataRepository(root:restored.workspace.appendingPathComponent("Data"),localState:restored.workspace.appendingPathComponent("Local"))
        XCTAssertEqual(try restoredRepo.loadInbox().count,3)
        XCTAssertEqual(try Data(contentsOf:restoredRepo.validatedURL(asset.attachment.path)),Data([1,2,3]))
    }
    func testAudioFailureCheckpointAndManualCorrectionsWin() throws {
        let (base, repo) = try LibraryTests().workspace(); defer { try? FileManager.default.removeItem(at:base) }
        let event = try update(voice:true), asset = try LibraryAttachments.prepare(data:Data([1]),name:"voice.ogg",extension:"ogg",localState:repo.localState)
        var root = try TelegramCapture.save(event,botID:1,ownerID:42,attachment:asset,repository:repo)
        root.titleOverride = "My voice note"; root.tagsOverride = ["Personal"]; root.revision += 1
        try repo.saveInbox(root,expectedRevision:1)
        let results = try TelegramCapture.finishAudio(update:event,botID:1,transcript:"An exact transcript",drafts:[TelegramDraft(CaptureDraft(title:"One")),TelegramDraft(CaptureDraft(title:"Two"))],repository:repo)
        XCTAssertEqual(results.count,1); XCTAssertFalse(results[0].archived); XCTAssertEqual(results[0].title,"My voice note"); XCTAssertEqual(results[0].tags,["Personal"])
        XCTAssertEqual(results[0].task(settings:PlanningSettings()).notes,"An exact transcript")
        var state = TelegramPollingState(); state.ownerID = 42; try state.receive([event]); state.jobs[0].chunkText = ["part-0000":"Русский текст"]; state.jobs[0].transcript = "Русский текст"; state.jobs[0].lastError = "Synthetic offline failure"
        let recovered = try JSONDecoder().decode(TelegramPollingState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(recovered.jobs[0].chunkText["part-0000"],"Русский текст"); XCTAssertEqual(recovered.jobs[0].transcript,"Русский текст")
    }
    func testDeliveryLedgerAndNotificationExpiry() throws {
        var state = TelegramPollingState(); let now = Date()
        state.queue(id:"event:a",text:"A",expiresAt:now.addingTimeInterval(-1)); state.queue(id:"event:a",text:"A")
        XCTAssertEqual(state.outbox.count,1)
        state.prune(now:now); XCTAssertTrue(state.outbox.isEmpty)
        state.delivered["digest:today"] = now; state.queue(id:"digest:today",text:"Plan"); XCTAssertTrue(state.outbox.isEmpty)
        state.delivered["urgent:stable"] = now.addingTimeInterval(-10*86400); state.prune(now:now)
        XCTAssertTrue(state.delivered["urgent:stable"] != nil)
        state.queue(id:"reply:1",text:"Saved"); state.outbox[0].attemptedAt = now
        let reopened = try JSONDecoder().decode(TelegramPollingState.self,from:JSONEncoder().encode(state))
        XCTAssertTrue(reopened.outbox[0].attemptedAt != nil)
    }
    func testCommandsUseActualDayFiltersAndBoundedPages() throws {
        let s = PlanningSettings(), now = ISO8601DateFormatter().date(from:"2026-11-12T12:00:00Z")!
        var work = PlannerTask(id:"aaaaaaaa-0000-0000-0000-000000000001",title:"Review map <draft>",tags:["Work"],state:.ready,importance:true,urgency:true,remainingMinutes:30,now:now)
        var personal = work; personal.id = "bbbbbbbb-0000-0000-0000-000000000001"; personal.title = "Buy mushrooms"; personal.area = .personal
        let tasks = [work,personal]
        let workReply = TelegramCommands.reply("/work",tasks:tasks,plans:[],inbox:[],settings:s,now:now)
        XCTAssertTrue(workReply.contains(work.title)); XCTAssertFalse(workReply.contains(personal.title))
        XCTAssertTrue(TelegramCommands.reply("/personal@planner_bot",tasks:tasks,plans:[],inbox:[],settings:s,now:now).contains(personal.title))
        XCTAssertTrue(TelegramCommands.reply("/task bbbbbbbb",tasks:tasks,plans:[],inbox:[],settings:s,now:now).contains("Personal"))
        XCTAssertTrue(TelegramCommands.reply("/today",tasks:tasks,plans:[],inbox:[],settings:s,now:now).contains("2026-11-12"))
        XCTAssertTrue(TelegramCommands.reply("/tomorrow",tasks:tasks,plans:[],inbox:[],settings:s,now:now).contains("2026-11-13"))
        let many = (0..<25).map { index -> PlannerTask in var value = work; value.id = String(format:"%08d",index); return value }
        XCTAssertTrue(TelegramCommands.reply("/tasks 2",tasks:many,plans:[],inbox:[],settings:s,now:now).contains("Page 2/3"))
        work.notes = String(repeating:"long ",count:2000)
        XCTAssertLessThanOrEqual(TelegramCommands.reply("/task aaaaaaaa",tasks:[work],plans:[],inbox:[],settings:s,now:now).count,4000)
        XCTAssertEqual(TelegramCommands.reply("/unknown",tasks:tasks,plans:[],inbox:[],settings:s,now:now),"Unknown command. /help lists available commands.")
    }
    func testBotIdentityUsesLocalizedTextAndFreshJPEGUpload() async throws {
        var localized:[String]=[], uploaded=false
        TelegramHTTPStub.handle = { request in
            let method=request.url!.lastPathComponent
            if method == "setMyProfilePhoto" {
                XCTAssertTrue(request.value(forHTTPHeaderField:"Content-Type")!.hasPrefix("multipart/form-data; boundary="))
                var bytes=request.httpBody ?? Data()
                if bytes.isEmpty, let stream=request.httpBodyStream { stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(contentsOf:buffer.prefix(n))} }
                let payload=String(decoding:bytes,as:UTF8.self)
                XCTAssertTrue(payload.contains("attach://avatar"));XCTAssertTrue(payload.contains("Content-Type: image/jpeg"));uploaded=true
                return (200,try self.data(["ok":true,"result":true]))
            }
            let body=try self.body(request)
            if method.hasPrefix("setMy") {
                let language=body["language_code"] as! String;localized.append(method+":"+language)
                if method == "setMyName" {XCTAssertEqual(body["name"] as? String,TelegramIdentity.name)}
                if method == "setMyShortDescription" {XCTAssertEqual(body["short_description"] as? String,TelegramIdentity.shortDescription(language:language))}
                if method == "setMyDescription" {XCTAssertEqual(body["description"] as? String,TelegramIdentity.description(language:language))}
                return (200,try self.data(["ok":true,"result":true]))
            }
            if method == "getMyName" {return (200,try self.data(["ok":true,"result":["name":TelegramIdentity.name]]))}
            if method == "getMyShortDescription" {return (200,try self.data(["ok":true,"result":["short_description":TelegramIdentity.shortDescription()]]))}
            if method == "getMyDescription" {return (200,try self.data(["ok":true,"result":["description":TelegramIdentity.description()]]))}
            if method == "getUserProfilePhotos" {return (200,try self.data(["ok":true,"result":["total_count":1,"photos":[[["file_id":"new-avatar","file_unique_id":"new"]]]]]))}
            return (200,try self.data(["ok":true,"result":["id":1,"is_bot":true,"username":"synthetic_bot"]]))
        }
        let result=try await client().applyIdentity(avatarJPEG:Data([0xff,0xd8,0xff,0x00]))
        XCTAssertTrue(uploaded);XCTAssertEqual(localized.count,9);XCTAssertTrue(localized.contains("setMyDescription:ru"));XCTAssertEqual(result.photoFileID,"new-avatar")
        XCTAssertLessThanOrEqual(TelegramIdentity.name.count,64)
        for language in ["","en","ru"] {XCTAssertLessThanOrEqual(TelegramIdentity.shortDescription(language:language).count,120);XCTAssertLessThanOrEqual(TelegramIdentity.description(language:language).count,512)}
        do {_ = try await client().applyIdentity(avatarJPEG:Data("not a JPEG".utf8));XCTAssertTrue(false)} catch {}
    }
    func testPollingHTTPAndOwnerDataNeverSentToAnotherChat() async throws {
        var methods: [String] = []
        TelegramHTTPStub.handle = { request in
            let method = request.url!.lastPathComponent; methods.append(method)
            let body = try self.body(request)
            if method == "getUpdates" {
                XCTAssertEqual(body["offset"] as? Int,77); XCTAssertEqual(body["timeout"] as? Int,0); XCTAssertEqual(body["allowed_updates"] as? [String],["message"])
                return (200,try self.data(["ok":true,"result":[]]))
            }
            if method == "sendMessage" {
                XCTAssertEqual(body["chat_id"] as? Int,42); XCTAssertEqual(body["text"] as? String,"💍 <b>Private task &lt;literal&gt;</b>")
                XCTAssertEqual(body["parse_mode"] as? String,"HTML"); XCTAssertEqual(body["protect_content"] as? Bool,true)
                return (200,try self.data(["ok":true,"result":["message_id":1]]))
            }
            return (200,try self.data(["ok":true,"result":["id":1,"is_bot":true,"username":"synthetic_bot"]]))
        }
        let api = try client(); XCTAssertEqual(try await api.me().id,1)
        XCTAssertEqual(try await api.updates(offset:77).count,0)
        try await api.send(chatID:42,text:"Private task <literal>")
        XCTAssertEqual(methods,["getMe","getUpdates","sendMessage"])
    }
    func testHTTPFailuresDoNotLeakBotTokensAndFilesCannotEscapeHost() async throws {
        for code in [401,409,429] {
            TelegramHTTPStub.handle = { _ in (code,try self.data(["ok":false,"error_code":code,"description":"ignored \(self.token)","parameters":["retry_after":17]])) }
            do { _ = try await client().me(); XCTAssertTrue(false) } catch { XCTAssertFalse(error.localizedDescription.contains(token)); if code == 429 { XCTAssertEqual((error as? TelegramBotError)?.retryAfter,17) } }
        }
        TelegramHTTPStub.handle = { request in throw NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut,userInfo:[NSURLErrorFailingURLStringErrorKey:request.url!.absoluteString]) }
        do { _ = try await client().me(); XCTAssertTrue(false) } catch { XCTAssertFalse(error.localizedDescription.contains(token)) }
        let event = try update(voice:true)
        TelegramHTTPStub.handle = { _ in (200,try self.data(["ok":true,"result":["file_path":"../escape.ogg","file_size":3]])) }
        do { _ = try await client().download(event.message!.voice!); XCTAssertTrue(false) } catch { XCTAssertFalse(error.localizedDescription.contains(token)) }
        var count = 0
        TelegramHTTPStub.handle = { _ in count += 1; return (200,try self.data(["ok":true,"result":[]])) }
        var oversized = event.message!.voice!; oversized.file_size = 21*1024*1024
        do { _ = try await client().download(oversized); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(count,0)
    }
}
