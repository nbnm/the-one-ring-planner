import Foundation
import RingCore

private final class PublicationMemory: GoogleCredentialStoring, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(_ name: String) -> Data? { values[name] }
    func write(_ data: Data, name: String) { values[name] = data }
    func remove(_ name: String) { values.removeValue(forKey: name) }
}
private actor PublicationAuthorizer: GoogleAuthorizing {
    var scopes: [String] = []
    func authorize(configuration: GoogleOAuthConfiguration, requestedScopes: [String]) async throws -> GoogleAuthorizationCode {
        scopes = requestedScopes
        return GoogleAuthorizationCode(code: "synthetic", redirect: URL(string: "http://127.0.0.1:12345/oauth2callback")!, verifier: "synthetic")
    }
    func cancel() {}
}
private final class PublicationHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class PublicationServer {
    var writeScope = true
    var owner = true
    var account = "owner@example.test"
    var events: [String: [String: Any]] = [:]
    var gone = Set<String>()
    var posts = 0, patches = 0, deletes = 0
    var lostInsert = false, lostPatch = false, precondition = false, denied = false
    var omitRefresh = false
    var forceColor: String?
    var requests: [URLRequest] = []
    var patchBodies: [[String: Any]] = []
    func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func body(_ request: URLRequest) -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(buffer, count: n) }
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
    func handle(_ request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        if request.url!.host == "oauth2.googleapis.com" {
            var token: [String: Any] = ["access_token": "synthetic-access", "expires_in": 3600, "token_type": "Bearer", "scope": (GoogleOAuth.scopes + (writeScope ? [GoogleOAuth.publishingScope] : [])).joined(separator: " ")]
            if !omitRefresh { token["refresh_token"] = "synthetic-refresh" }
            return (200, data(token))
        }
        if request.url!.path.hasSuffix("calendarList") {
            return (200, data(["kind": "calendar#calendarList", "items": [["id": account, "summary": "Work", "primary": true, "accessRole": owner ? "owner" : "reader", "timeZone": "America/Toronto"]]]))
        }
        if denied { return (403, Data()) }
        let method = request.httpMethod ?? "GET", id = request.url!.lastPathComponent
        if method == "GET", id == "events" { return (200, data(["kind": "calendar#events", "timeZone": "America/Toronto", "items": Array(events.values)])) }
        if method == "GET" { return gone.contains(id) ? (410, Data()) : events[id].map { (200, data($0)) } ?? (404, Data()) }
        if method == "POST" {
            var value = body(request); let id = value["id"] as! String
            if let forceColor { value["colorId"] = forceColor }
            if events[id] != nil { return (409, Data()) }
            posts += 1; value["kind"] = "calendar#event"; value["etag"] = "\"v1\""; events[id] = value
            if lostInsert { lostInsert = false; throw URLError(.timedOut) }
            return (200, data(value))
        }
        if precondition || request.value(forHTTPHeaderField: "If-Match") != events[id]?["etag"] as? String { return (412, Data()) }
        if method == "PATCH" {
            patches += 1; var value = events[id] ?? [:]
            let fields = body(request); patchBodies.append(fields)
            for (key, field) in fields { value[key] = field }; value["etag"] = "\"v\(patches + 1)\""; events[id] = value
            if let forceColor { value["colorId"] = forceColor; events[id] = value }
            if lostPatch { lostPatch = false; throw URLError(.timedOut) }
            return (200, data(value))
        }
        if method == "DELETE" { deletes += 1; events.removeValue(forKey: id); gone.insert(id); return (204, Data()) }
        return (500, Data())
    }
}

struct CalendarPublishingTests {
    let workspace = "c139a7a0-5bcf-4f48-a48b-dc02879a0aa6"
    let settings = PlanningSettings()
    var day: Date { ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")! }
    func plan() -> DayPlan {
        let task = PlannerTask(id: "work", title: "Prepare proposal", context: "T1A", state: .ready, importance: true, urgency: false, remainingMinutes: 60)
        return Scheduler().makePlan(day: day, now: PlannerDate.at(480, on: day, settings: settings), tasks: [task], routines: [], settings: settings)
    }
    func job(_ plan: DayPlan? = nil) -> CalendarPublication {
        CalendarPublication(plan: plan ?? self.plan(), workspaceID: workspace,
            destination: PublicationDestination(id: "owner@example.test", title: "Work", accountID: "owner@example.test", primary: true), timeZone: settings.timeZone)
    }
    func routines() -> [Routine] {
        [Routine(id: "read", title: "Read a chapter", minutes: 20, startMinute: 540, endMinute: 660, enabled: true),
         Routine(id: "review", title: "Close the day", minutes: 10, startMinute: 990, endMinute: 1020, protected: true, enabled: true, weekdays: [.tuesday])]
    }
    func routinePlan(on date: Date? = nil, routines: [Routine]? = nil) -> DayPlan {
        Scheduler().makePlan(day: date ?? day, now: PlannerDate.at(480, on: day, settings: settings), tasks: [], routines: routines ?? self.routines(), settings: settings)
    }
    func testRoutinePublicationUsesOnlyScheduledOccurrencesAndDistinctDates() {
        var disabled = routines()[0]; disabled.id = "disabled"; disabled.enabled = false
        let impossible = Routine(id: "overflow", title: "Long practice", minutes: 120, startMinute: 540, endMinute: 545, enabled: true)
        var p = routinePlan(routines: routines() + [disabled, impossible])
        let publication = job(p)
        XCTAssertEqual(publication.desired.count, 2)
        XCTAssertTrue(publication.desired.allSatisfy { $0.kind == .routine && $0.taskID == nil && $0.hasValidSource })
        XCTAssertEqual(Set(publication.desired.compactMap(\.routineID)), Set(["read", "review"]))
        XCTAssertEqual(job(p).desired, publication.desired)
        let nextDay = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        let tomorrow = job(routinePlan(on: nextDay))
        XCTAssertEqual(tomorrow.desired.compactMap(\.routineID), ["read"])
        XCTAssertTrue(Set(tomorrow.desired.map(\.id)).isDisjoint(with: publication.desired.map(\.id)))
        let indices = p.blocks.indices.filter { p.blocks[$0].kind == .routine }
        p.blocks[indices[0]].state = .completed; p.blocks[indices[1]].state = .skipped
        XCTAssertEqual(job(p).desired.count, 1)
        XCTAssertEqual(job(p).desired[0].blockID, p.blocks[indices[0]].id)
        p.blocks[indices[0]].state = .interrupted
        XCTAssertTrue(job(p).desired.isEmpty)
    }
    func testLegacyTaskPublicationsAndRoutineRecordsSurviveRestart() throws {
        let legacy = job()
        let encoded = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertTrue((object["desired"] as! [[String: Any]]).allSatisfy { $0["routineID"] == nil && $0["taskID"] != nil })
        let decoded = try JSONDecoder().decode(CalendarPublication.self, from: encoded)
        XCTAssertEqual(decoded, legacy)
        XCTAssertTrue(decoded.desired.allSatisfy { CalendarPlanEvent.isOwned(eventID: $0.id, metadata: $0.metadata(workspaceID: workspace, day: decoded.day), workspaceID: workspace) })
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        var p = routinePlan(); p.publication = job(p); p.status = .local
        try repo.save(plan: p, message: "Confirm routines")
        let restarted = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try restarted.load(DayPlan.self, directory: "plans"), [p])
        XCTAssertTrue(p.publication!.matches(p, timeZone: settings.timeZone))
        p.blocks[p.blocks.firstIndex { $0.kind == .routine }!].start.addTimeInterval(300)
        XCTAssertEqual(p.publication!.invalidatingChanges(in: p, timeZone: settings.timeZone).state, .needsConfirmation)
    }
    func testQ2RetainsConfirmedRoutinesAndLeavesDraftRoutinesUnpublished() {
        let task = PlannerTask(id: "q2", title: "Prepare the next release", state: .ready, importance: true, urgency: false, remainingMinutes: 60)
        let p = routinePlan(), now = PlannerDate.at(480, on: day, settings: settings)
        func accept(_ previous: DayPlan) -> DayPlan {
            let slot = TaskSlotPlanner.suggestions(task: task, minutes: 60, day: day, now: now, tasks: [task], routines: routines(), settings: settings, meetings: [], previous: previous, notBeforeMinute: 540)[0]
            return TaskSlotPlanner.accepting(slot, task: task, now: now, tasks: [task], routines: routines(), settings: settings, meetings: [], previous: previous)
        }
        let accepted = accept(p), added = accepted.blocks.first { $0.taskID == task.id }!
        let scoped = CalendarPublication(plan: accepted, workspaceID: workspace, destination: job().destination, timeZone: settings.timeZone, confirmedBlockIDs: [added.id], keepingExistingEvents: true)
        XCTAssertEqual(scoped.desired.count, 1)
        XCTAssertEqual(scoped.desired[0].taskID, task.id)
        XCTAssertTrue(scoped.hasUnconfirmedEvents(in: accepted, timeZone: settings.timeZone))
        var confirmed = p; confirmed.publication = job(p)
        let withPrior = accept(confirmed), newBlock = withPrior.blocks.first { $0.taskID == task.id }!
        let carried = CalendarPublication(plan: withPrior, workspaceID: workspace, destination: job().destination, timeZone: settings.timeZone, confirmedBlockIDs: [newBlock.id], keepingExistingEvents: true)
        XCTAssertEqual(carried.desired.filter { $0.routineID != nil }, confirmed.publication!.desired)
        XCTAssertTrue(carried.matches(withPrior, timeZone: settings.timeZone))
        XCTAssertFalse(carried.hasUnconfirmedEvents(in: withPrior, timeZone: settings.timeZone))
        XCTAssertEqual(withPrior.blocks.filter { $0.kind == .routine }.count, 2)
        XCTAssertTrue(withPrior.blocks.first { $0.routineID == "review" }!.protected)
    }
    private func fixture(write: Bool = true) async throws -> (PublicationServer, GoogleCalendarProvider, GoogleOAuthClient, PublicationAuthorizer) {
        let server = PublicationServer(); server.writeScope = write
        PublicationHTTP.handler = { try server.handle($0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PublicationHTTP.self]
        let session = URLSession(configuration: config)
        let authorizer = PublicationAuthorizer()
        let oauth = GoogleOAuthClient(storage: PublicationMemory(), authorizer: authorizer, session: session)
        try await oauth.configure(Data(#"{"installed":{"client_id":"synthetic.apps.googleusercontent.com"}}"#.utf8))
        try await oauth.signIn(publishing: write)
        return (server, GoogleCalendarProvider(oauth: oauth, session: session, workspaceID: workspace), oauth, authorizer)
    }
    func testPendingPublicationSurvivesRestartAndWorkspaceIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        let id = try repo.workspaceID()
        var p = plan(); p.publication = job(p); p.status = .local
        try repo.save(plan: p, message: "Confirm and queue publication")
        let restarted = try DataRepository(root: repo.root, localState: repo.localState)
        XCTAssertEqual(try restarted.workspaceID(), id)
        XCTAssertEqual(try restarted.load(DayPlan.self, directory: "plans"), [p])
        var changed = p; changed.blocks.removeAll { $0.kind == .focus }
        XCTAssertEqual(p.publication!.invalidatingChanges(in: changed, timeZone: settings.timeZone).state, .needsConfirmation)
    }
    func testExternalMovesAreReadByIDAndReconfirmedWithoutWritesOrDuplicates() async throws {
        let (server, provider, _, _) = try await fixture()
        var p = routinePlan()
        p.blocks += plan().blocks.filter { $0.taskID != nil }
        p.publication = job(p)
        try await provider.synchronize(p.publication!)
        p.publication!.state = .published; p.publication!.known = p.publication!.desired
        let f = ISO8601DateFormatter(), beforeReads = server.requests.count, created = server.posts
        for event in p.publication!.desired {
            server.events[event.id]!["start"] = ["dateTime": f.string(from: event.start.addingTimeInterval(9 * 86400)), "timeZone": settings.timeZone]
            server.events[event.id]!["end"] = ["dateTime": f.string(from: event.end.addingTimeInterval(9 * 86400)), "timeZone": settings.timeZone]
        }
        let times = try await provider.eventTimes(p.publication!)
        XCTAssertEqual(times.count, p.publication!.desired.count)
        XCTAssertTrue(server.requests.dropFirst(beforeReads).allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(server.requests.dropFirst(beforeReads).filter { $0.url!.path.contains("/events/") }.allSatisfy { $0.url!.query == nil })
        let moved = CalendarSchedule.reconciling(p, times: times, settings: settings).plan
        XCTAssertTrue(moved.publication!.matches(moved, timeZone: settings.timeZone))
        let confirmation = job(moved)
        try await provider.synchronize(confirmation, expectedTimes: times)
        XCTAssertEqual(server.posts, created); XCTAssertEqual(server.patches, 0); XCTAssertEqual(server.deletes, 0)
        let event = moved.publication!.desired[0]
        server.events[event.id]!["start"] = ["dateTime": f.string(from: event.start.addingTimeInterval(300))]
        server.events[event.id]!["end"] = ["dateTime": f.string(from: event.end.addingTimeInterval(300))]
        do { try await provider.synchronize(confirmation, expectedTimes: times); XCTAssertTrue(false) } catch CalendarPublicationError.conflict {}
        XCTAssertEqual(server.patches, 0)
    }
    func testScheduleReadsUseReadPermissionAndRejectForeignInvalidAndDeletedEvents() async throws {
        let (server, provider, oauth, _) = try await fixture(write: false)
        let publication = job(), f = ISO8601DateFormatter()
        for event in publication.desired {
            server.events[event.id] = ["id": event.id, "kind": "calendar#event", "etag": "synthetic", "status": "confirmed",
                "start": ["dateTime": f.string(from: event.start)], "end": ["dateTime": f.string(from: event.end)],
                "extendedProperties": ["private": event.metadata(workspaceID: workspace, day: publication.day)]]
        }
        XCTAssertFalse(await oauth.publishingAuthorized())
        XCTAssertEqual(try await provider.eventTimes(publication).count, publication.desired.count)
        let first = publication.desired[0], original = server.events[first.id]!
        server.events[first.id]!["extendedProperties"] = ["private": ["ringWorkspace": "foreign"]]
        do { _ = try await provider.eventTimes(publication); XCTAssertTrue(false) } catch CalendarPublicationError.foreignEvent {}
        server.events[first.id] = original
        server.events[first.id]!["start"] = ["date": "2026-10-27"]
        do { _ = try await provider.eventTimes(publication); XCTAssertTrue(false) } catch GoogleCalendarError.invalidResponse {}
        server.events.removeValue(forKey: first.id)
        do { _ = try await provider.eventTimes(publication); XCTAssertTrue(false) } catch CalendarPublicationError.removedEvent {}
        XCTAssertEqual(try await provider.eventTimes(publication, missingAllowed: true).count, publication.desired.count - 1)
        server.gone.insert(first.id)
        do { _ = try await provider.eventTimes(publication, missingAllowed: true); XCTAssertTrue(false) } catch CalendarPublicationError.removedEvent {}
        let remaining = try await provider.eventTimes(publication, skippingRemoved: true)
        XCTAssertEqual(remaining.count, publication.desired.count - 1)
        XCTAssertFalse(remaining.contains { $0.id == first.id })
        var pending = plan(); pending.publication = publication
        let moves = remaining.map { CalendarEventTime(id: $0.id, start: $0.start.addingTimeInterval(300), end: $0.end.addingTimeInterval(300)) }
        let update = CalendarSchedule.reconciling(pending, times: moves, settings: settings, includingPending: true)
        XCTAssertEqual(update.changedEvents, remaining.count)
        XCTAssertTrue(update.conflicts.isEmpty)
        XCTAssertEqual(update.plan.blocks.first { $0.id == first.blockID }?.start, first.start)
        let cancelled = publication.desired[1]
        server.events[cancelled.id] = ["id": cancelled.id, "kind": "calendar#event", "status": "cancelled"]
        XCTAssertEqual(try await provider.eventTimes(publication, skippingRemoved: true).count, publication.desired.count - 2)
        server.account = "another@example.test"
        do { _ = try await provider.eventTimes(publication); XCTAssertTrue(false) } catch CalendarPublicationError.account {}
        XCTAssertEqual(server.posts, 0); XCTAssertEqual(server.patches, 0); XCTAssertEqual(server.deletes, 0)
    }
    func testCreatesPrivateEventsAndRepeatedConfirmationIsIdempotent() async throws {
        let (server, provider, _, _) = try await fixture()
        let publication = job()
        try await provider.synchronize(publication); try await provider.synchronize(publication)
        XCTAssertEqual(server.posts, publication.desired.count)
        XCTAssertEqual(server.events.count, publication.desired.count)
        XCTAssertEqual(server.patches, 0)
        for value in server.events.values {
            XCTAssertEqual(value["colorId"] as? String, "11")
            XCTAssertEqual(value["visibility"] as? String, "private")
            XCTAssertEqual(value["transparency"] as? String, "opaque")
            XCTAssertTrue(value["attendees"] == nil)
            XCTAssertEqual((value["reminders"] as? [String: Bool])?["useDefault"], false)
        }
        for request in server.requests where ["POST", "PATCH", "DELETE"].contains(request.httpMethod ?? "") && request.url?.host == "www.googleapis.com" {
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sendUpdates" }?.value, "none")
        }
    }
    func testRoutineEventsRetryWithoutDuplicatesAndDoNotBlockTheirOwnPlan() async throws {
        let (server, provider, _, _) = try await fixture()
        let publication = job(routinePlan()); server.lostInsert = true
        do { try await provider.synchronize(publication); XCTAssertTrue(false) } catch {}
        try await provider.synchronize(publication); try await provider.synchronize(publication)
        XCTAssertEqual(server.posts, 2); XCTAssertEqual(server.events.count, 2); XCTAssertEqual(server.patches, 0)
        for event in publication.desired {
            let remote = server.events[event.id]!, metadata = (remote["extendedProperties"] as! [String: [String: String]])["private"]!
            XCTAssertEqual(metadata["ringRoutine"], event.routineID); XCTAssertTrue(metadata["ringTask"] == nil)
            XCTAssertEqual(remote["visibility"] as? String, "private"); XCTAssertEqual(remote["transparency"] as? String, "opaque")
            XCTAssertEqual(remote["colorId"] as? String, "10")
            XCTAssertTrue(remote["recurrence"] == nil && remote["attendees"] == nil)
        }
        _ = try await provider.calendars(refresh: true)
        let calendar = PlannerDate.calendar(settings), start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        let events = try await provider.occurrences(in: interval, calendarIDs: ["owner@example.test"])
        XCTAssertEqual(events.count, 2); XCTAssertTrue(events.allSatisfy { $0.managedByPlanner && $0.busy })
        XCTAssertTrue(events.allSatisfy { $0.plannerCategory == .routine && $0.colorID == "10" })
        XCTAssertTrue(try CalendarRead(interval: interval, calendarIDs: ["owner@example.test"], events: events).meetings(day: day, settings: settings).isEmpty)
    }
    func testRoutineReconfirmationUpdatesAndRemovesObsoleteOccurrences() async throws {
        let (server, provider, _, _) = try await fixture()
        var p = routinePlan(); p.publication = job(p)
        try await provider.synchronize(p.publication!)
        let first = p.blocks.firstIndex { $0.routineID == "read" }!
        p.blocks[first].start.addTimeInterval(300); p.blocks[first].end.addTimeInterval(300); p.blocks[first].title = "Read the next chapter"
        p.blocks.removeAll { $0.routineID == "review" }
        let updated = job(p)
        try await provider.synchronize(updated); try await provider.synchronize(updated)
        XCTAssertEqual(server.patches, 1); XCTAssertEqual(server.deletes, 1); XCTAssertEqual(server.events.count, 1)
        XCTAssertEqual(server.events.values.first!["summary"] as? String, "Read the next chapter")
        p.publication = updated
        p.blocks.removeAll { $0.kind == .routine }
        try await provider.synchronize(job(p))
        XCTAssertTrue(server.events.isEmpty); XCTAssertEqual(server.deletes, 2)
    }
    func testRoutineOwnershipCannotBeSubstitutedWithTaskMetadata() async throws {
        let (server, provider, _, _) = try await fixture()
        let publication = job(routinePlan())
        try await provider.synchronize(publication)
        let event = publication.desired[0]
        var metadata = event.metadata(workspaceID: workspace, day: publication.day)
        metadata["ringTask"] = "pretend-task"
        XCTAssertFalse(CalendarPlanEvent.isOwned(eventID: event.id, metadata: metadata, workspaceID: workspace))
        metadata.removeValue(forKey: "ringRoutine")
        server.events[event.id]?["extendedProperties"] = ["private": metadata]
        do { try await provider.synchronize(publication); XCTAssertTrue(false) } catch CalendarPublicationError.foreignEvent {}
        XCTAssertEqual(server.patches, 0); XCTAssertEqual(server.deletes, 0)
    }
    func testLostInsertResponseRetriesWithoutDuplicates() async throws {
        let (server, provider, _, _) = try await fixture(); server.lostInsert = true
        do { try await provider.synchronize(job()); XCTAssertTrue(false) } catch {}
        try await provider.synchronize(job())
        XCTAssertEqual(server.events.count, job().desired.count)
        XCTAssertEqual(server.posts, job().desired.count)
    }
    func testColorRepairPreservesExistingDetailsAndIsIdempotent() async throws {
        let (server, provider, _, _) = try await fixture()
        let task = PlannerTask(id: "colored-task", title: "Prepare release", state: .ready, importance: true, urgency: false, remainingMinutes: 60)
        let p = Scheduler().makePlan(day: day, now: PlannerDate.at(480, on: day, settings: settings), tasks: [task], routines: routines(), settings: settings)
        let publication = job(p)
        try await provider.synchronize(publication)
        for id in Array(server.events.keys) { server.events[id]!.removeValue(forKey: "colorId") }
        let moved = publication.desired[0]
        let formatter = ISO8601DateFormatter()
        server.events[moved.id]?["summary"] = "Edited in Google"
        server.events[moved.id]?["description"] = "Keep these notes"
        server.events[moved.id]?["start"] = ["dateTime": formatter.string(from: moved.start.addingTimeInterval(3600)), "timeZone": moved.timeZone]
        server.events[moved.id]?["end"] = ["dateTime": formatter.string(from: moved.end.addingTimeInterval(3600)), "timeZone": moved.timeZone]
        server.events["unrelated"] = ["id": "unrelated", "summary": "Unrelated meeting", "colorId": "9"]
        let before = server.events, posts = server.posts
        XCTAssertEqual(try await provider.applyEventColors(publication), publication.desired.count)
        XCTAssertEqual(try await provider.applyEventColors(publication), 0)
        XCTAssertEqual(server.posts, posts); XCTAssertEqual(server.deletes, 0); XCTAssertEqual(server.patches, publication.desired.count)
        for event in publication.desired {
            var actual = server.events[event.id]!, expected = before[event.id]!
            XCTAssertEqual(actual.removeValue(forKey: "colorId") as? String, event.googleColorID)
            actual.removeValue(forKey: "etag"); expected.removeValue(forKey: "etag")
            XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
        }
        XCTAssertTrue(NSDictionary(dictionary: server.events["unrelated"]!).isEqual(to: before["unrelated"]!))
        for fields in server.patchBodies {
            XCTAssertEqual(Set(fields.keys), Set(["colorId"]))
        }
    }
    func testColorRepairSkipsMissingEventsAndRetainsOwnershipAndETagGuards() async throws {
        let (server, provider, _, _) = try await fixture()
        let publication = job(); try await provider.synchronize(publication)
        let first = publication.desired[0].id, second = publication.desired[1].id, original = server.events[first]!
        server.gone.insert(first); server.events.removeValue(forKey: second)
        XCTAssertEqual(try await provider.applyEventColors(publication), 0)
        XCTAssertEqual(server.posts, publication.desired.count); XCTAssertEqual(server.deletes, 0)
        server.gone.remove(first); server.events[first]?["extendedProperties"] = ["private": ["ringWorkspace": "foreign"]]
        do { try await provider.applyEventColors(publication); XCTAssertTrue(false) } catch CalendarPublicationError.foreignEvent {}
        server.events[first] = original; server.events[first]!.removeValue(forKey: "colorId"); server.precondition = true
        do { try await provider.applyEventColors(publication); XCTAssertTrue(false) } catch CalendarPublicationError.conflict {}
        XCTAssertEqual(server.patches, 0)
        server.precondition = false; server.account = "another@example.test"
        do { try await provider.applyEventColors(publication); XCTAssertTrue(false) } catch CalendarPublicationError.account {}
        server.account = "owner@example.test"; server.owner = false
        do { try await provider.applyEventColors(publication); XCTAssertTrue(false) } catch CalendarPublicationError.destination {}
        XCTAssertEqual(server.patches, 0)
    }
    func testWrongColorResponsesCannotReportSuccessfulPublication() async throws {
        let (server, provider, _, _) = try await fixture()
        let publication = job(); server.forceColor = "9"
        do { try await provider.synchronize(publication); XCTAssertTrue(false) } catch GoogleCalendarError.invalidResponse {}
        server.forceColor = nil; try await provider.synchronize(publication)
        XCTAssertEqual(server.posts, publication.desired.count)
        XCTAssertTrue(server.events.values.allSatisfy { $0["colorId"] as? String == "11" })
        for id in Array(server.events.keys) { server.events[id]!.removeValue(forKey: "colorId") }
        server.forceColor = "9"
        do { try await provider.applyEventColors(publication); XCTAssertTrue(false) } catch GoogleCalendarError.invalidResponse {}
        server.forceColor = nil
        XCTAssertEqual(try await provider.applyEventColors(publication), publication.desired.count)
        XCTAssertEqual(try await provider.applyEventColors(publication), 0)
        XCTAssertEqual(server.posts, publication.desired.count); XCTAssertEqual(server.deletes, 0)
    }
    func testReconfirmationUpdatesTimesAndRemovesOnlyObsoleteOwnedBlocks() async throws {
        let (server, provider, _, _) = try await fixture()
        var p = plan(); p.publication = job(p)
        try await provider.synchronize(p.publication!)
        let ids = p.blocks.indices.filter { p.blocks[$0].kind == .focus }
        p.blocks[ids[0]].start = p.blocks[ids[0]].start.addingTimeInterval(300)
        p.blocks[ids[0]].end = p.blocks[ids[0]].end.addingTimeInterval(300)
        p.blocks.remove(at: ids.last!)
        let updated = job(p)
        try await provider.synchronize(updated)
        XCTAssertEqual(server.events.count, updated.desired.count)
        XCTAssertEqual(server.patches, 1)
        XCTAssertEqual(server.deletes, 1)
        try await provider.synchronize(updated)
        XCTAssertEqual(server.patches, 1)
    }
    func testOwnershipAccountAndConcurrentEditsFailClosed() async throws {
        let (server, provider, _, _) = try await fixture(); let p = job()
        try await provider.synchronize(p)
        let id = p.desired[0].id
        server.events[id]?["extendedProperties"] = ["private": ["ringWorkspace": "foreign"]]
        do { try await provider.synchronize(p); XCTAssertTrue(false) } catch CalendarPublicationError.foreignEvent {}
        XCTAssertEqual(server.patches, 0); XCTAssertEqual(server.deletes, 0)
        server.account = "other@example.test"
        do { try await provider.synchronize(p); XCTAssertTrue(false) } catch CalendarPublicationError.account {}
        server.account = "owner@example.test"; server.owner = false
        do { try await provider.synchronize(p); XCTAssertTrue(false) } catch CalendarPublicationError.destination {}
        server.owner = true; server.events[id]?["extendedProperties"] = ["private": p.desired[0].metadata(workspaceID: workspace, day: p.day)]
        server.events[id]?["summary"] = "Changed elsewhere"; server.precondition = true
        do { try await provider.synchronize(p); XCTAssertTrue(false) } catch CalendarPublicationError.conflict {}
        XCTAssertEqual(server.events[id]?["summary"] as? String, "Changed elsewhere")
    }
    func testWritingPermissionUpgradePreservesReadConnectionWhenDeclined() async throws {
        let (server, provider, oauth, authorizer) = try await fixture(write: false)
        XCTAssertTrue(await oauth.authorized()); XCTAssertFalse(await oauth.publishingAuthorized())
        do { try await provider.synchronize(job()); XCTAssertTrue(false) } catch GoogleCalendarError.publishingPermission {}
        do { try await oauth.signIn(publishing: true); XCTAssertTrue(false) } catch GoogleCalendarError.publishingPermission {}
        XCTAssertTrue(await oauth.authorized())
        XCTAssertTrue(await authorizer.scopes.contains(GoogleOAuth.publishingScope))
        server.writeScope = true; try await oauth.signIn(publishing: true)
        XCTAssertTrue(await oauth.publishingAuthorized())
        try await provider.synchronize(job())
    }
    func testPublishedTasksStayVisibleButDoNotBlockTheirOwnReplan() async throws {
        let (server, provider, _, _) = try await fixture(); try await provider.synchronize(job())
        _ = try await provider.calendars(refresh: true)
        let calendar = PlannerDate.calendar(settings), start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        var events = try await provider.occurrences(in: interval, calendarIDs: ["owner@example.test"])
        XCTAssertTrue(events.allSatisfy { $0.managedByPlanner && $0.busy })
        XCTAssertTrue(events.allSatisfy { $0.plannerCategory == .task && $0.colorID == "11" })
        let read = CalendarRead(interval: interval, calendarIDs: ["owner@example.test"], events: events)
        XCTAssertTrue(try read.meetings(day: day, settings: settings).isEmpty)
        var spoof = server.events.values.first!; spoof["id"] = "unrelated-meeting"; server.events["unrelated-meeting"] = spoof
        events = try await provider.occurrences(in: interval, calendarIDs: ["owner@example.test"])
        XCTAssertEqual(events.filter { !$0.managedByPlanner }.count, 1)
    }
    func testDeletedEventsAndForbiddenWritesRemainVisibleFailures() async throws {
        let (server, provider, _, _) = try await fixture()
        server.denied = true
        do { try await provider.synchronize(job()); XCTAssertTrue(false) } catch GoogleCalendarError.api(403) {}
        XCTAssertEqual(server.posts, 0)
        server.denied = false; server.gone.insert(job().desired[0].id)
        do { try await provider.synchronize(job()); XCTAssertTrue(false) } catch CalendarPublicationError.removedEvent {}
        XCTAssertEqual(server.posts, 0)
    }
    func testNewConsentNeverMixesAnOldAccountsRefreshToken() async throws {
        let (server, _, oauth, _) = try await fixture(write: false)
        server.omitRefresh = true; server.writeScope = true
        do { try await oauth.signIn(publishing: true); XCTAssertTrue(false) } catch GoogleCalendarError.offlineAuthorization {}
        XCTAssertTrue(await oauth.authorized())
        XCTAssertFalse(await oauth.publishingAuthorized())
    }
}


extension CalendarPublishingTests {
    private func edit(_ p: CalendarPublication, creating: Bool = false) -> CalendarBlockEdit {
        let e = p.desired[0]
        var scope = p; scope.desired = [e.rescheduled(start: e.start.addingTimeInterval(86400), end: e.end.addingTimeInterval(88200))]; scope.known = [e]
        return CalendarBlockEdit(publication: scope, baselineStart: e.start, baselineEnd: e.end, creating: creating)
    }
    func testScopedCalendarEditPreservesDetailsAndOtherEvents() async throws {
        let (server, provider, _, _) = try await fixture()
        let original = job(routinePlan()), change = edit(original)
        try await provider.synchronize(original)
        let id = change.event.id, other = original.desired.first { $0.id != id }!
        let untouched = server.data(server.events[other.id]!)
        server.events[id]!["summary"] = "Renamed in Google"
        server.events[id]!["description"] = "Personal notes"
        server.events[id]!["colorId"] = "7"
        let posts = server.posts
        try await provider.applyBlockEdit(change)
        XCTAssertEqual(server.posts, posts); XCTAssertEqual(server.deletes, 0); XCTAssertEqual(server.patches, 1)
        XCTAssertEqual(Set(server.patchBodies[0].keys), Set(["start", "end"]))
        XCTAssertEqual(server.events[id]!["summary"] as? String, "Renamed in Google")
        XCTAssertEqual(server.events[id]!["description"] as? String, "Personal notes")
        XCTAssertEqual(server.events[id]!["colorId"] as? String, "7")
        XCTAssertEqual(server.events[other.id]!["start"] as? [String:String], (try JSONSerialization.jsonObject(with: untouched) as! [String:Any])["start"] as? [String:String])
        try await provider.applyBlockEdit(change)
        XCTAssertEqual(server.patches, 1)
        XCTAssertTrue(server.requests.filter { $0.httpMethod == "PATCH" }.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") != nil && $0.url!.query!.contains("sendUpdates=none") })
    }
    func testScopedEditConflictsDeletionAndOwnershipFailClosed() async throws {
        let (server, provider, _, _) = try await fixture()
        let original = job(), change = edit(original), id = change.event.id
        try await provider.synchronize(original)
        server.events[id]!["start"] = ["dateTime": ISO8601DateFormatter().string(from: change.baselineStart.addingTimeInterval(1200))]
        do { try await provider.applyBlockEdit(change); XCTAssertTrue(false) } catch CalendarPublicationError.conflict {}
        XCTAssertEqual(server.patches, 0)
        server.events[id]!["start"] = ["dateTime": ISO8601DateFormatter().string(from: change.baselineStart)]
        server.precondition = true
        do { try await provider.applyBlockEdit(change); XCTAssertTrue(false) } catch CalendarPublicationError.conflict {}
        server.precondition = false
        var foreign = server.events[id]!
        foreign["extendedProperties"] = ["private": ["ringWorkspace":"foreign"]]; server.events[id] = foreign
        do { try await provider.applyBlockEdit(change); XCTAssertTrue(false) } catch CalendarPublicationError.foreignEvent {}
        server.events.removeValue(forKey: id)
        do { try await provider.applyBlockEdit(change); XCTAssertTrue(false) } catch CalendarPublicationError.removedEvent {}
        XCTAssertEqual(server.posts, original.desired.count); XCTAssertEqual(server.patches, 0); XCTAssertEqual(server.deletes, 0)
    }
    func testScopedEditUnknownResponsesRetryWithoutDuplicates() async throws {
        let (server, provider, _, _) = try await fixture()
        let original = job(), change = edit(original)
        try await provider.synchronize(original)
        server.lostPatch = true
        do { try await provider.applyBlockEdit(change); XCTAssertTrue(false) } catch is URLError {}
        try await provider.applyBlockEdit(change)
        XCTAssertEqual(server.patches, 1)
        let routine = edit(job(routinePlan()), creating: true)
        server.lostInsert = true
        do { try await provider.applyBlockEdit(routine); XCTAssertTrue(false) } catch is URLError {}
        let posts = server.posts
        try await provider.applyBlockEdit(routine)
        XCTAssertEqual(server.posts, posts); XCTAssertEqual(server.patches, 1)
        XCTAssertEqual(server.events[routine.event.id]!["colorId"] as? String, "10")
    }
    func testScopedEditRequiresWritingAndOriginalAccount() async throws {
        let (server, provider, _, _) = try await fixture(write: false)
        do { try await provider.applyBlockEdit(edit(job())); XCTAssertTrue(false) } catch GoogleCalendarError.publishingPermission {}
        XCTAssertEqual(server.posts, 0)
        let (otherServer, otherProvider, _, _) = try await fixture()
        otherServer.account = "different@example.test"
        do { try await otherProvider.applyBlockEdit(edit(job())); XCTAssertTrue(false) } catch CalendarPublicationError.account {}
        XCTAssertEqual(otherServer.posts, 0)
    }
}
