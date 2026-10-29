import Foundation
import RingCore

private final class GoogleMemoryStore: GoogleCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(_ name: String) -> Data? { lock.lock(); defer { lock.unlock() }; return data[name] }
    func write(_ value: Data, name: String) { lock.lock(); defer { lock.unlock() }; data[name] = value }
    func remove(_ name: String) { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: name) }
}
private actor GoogleAuthStub: GoogleAuthorizing {
    var hold = false
    var pending: CheckedContinuation<GoogleAuthorizationCode, Error>?
    func authorize(configuration: GoogleOAuthConfiguration, requestedScopes: [String]) async throws -> GoogleAuthorizationCode {
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return GoogleAuthorizationCode(code: "synthetic-code+&", redirect: URL(string: "http://127.0.0.1:12345/oauth2callback")!, verifier: "synthetic-verifier")
    }
    func cancel() { pending?.resume(throwing: GoogleCalendarError.cancelled); pending = nil }
    func suspend() { hold = true }
    func waiting() -> Bool { pending != nil }
}
private actor BrowserOpened {
    var value = false
    func mark() { value = true }
}
private final class GoogleHTTPStub: URLProtocol {
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

struct GoogleCalendarTests {
    private let credentials = Data(#"{"installed":{"client_id":"synthetic-client.apps.googleusercontent.com","client_secret":"synthetic-secret"}}"#.utf8)
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GoogleHTTPStub.self]
        return URLSession(configuration: config)
    }
    private func token(_ access: String = "first-access", refresh: Bool = true, scopes: String? = GoogleOAuth.scopes.joined(separator: " ")) -> Data {
        var value: [String: Any] = ["access_token": access, "expires_in": 3600, "token_type": "Bearer"]
        if refresh { value["refresh_token"] = "synthetic-refresh" }
        if let scopes { value["scope"] = scopes }
        return try! JSONSerialization.data(withJSONObject: value)
    }
    private func body(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        let items = URLComponents(string: "https://example.test/?" + String(decoding: data, as: UTF8.self))?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    func testPKCEAndVerifiedCallbacks() throws {
        XCTAssertEqual(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = try GoogleOAuth.randomString()
        XCTAssertEqual(verifier.count, 43); XCTAssertTrue(verifier != (try GoogleOAuth.randomString()))
        let redirect = URL(string: "http://127.0.0.1:12345/oauth2callback")!
        let url = GoogleOAuth.authorizationURL(clientID: "synthetic", redirect: redirect, state: "expected", verifier: verifier)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, GoogleOAuth.scopes.joined(separator: " "))
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertTrue(query.first { $0.name == "code_verifier" } == nil)
        XCTAssertEqual(try GoogleOAuth.code(from: URL(string: redirect.absoluteString + "?state=expected&code=good")!, redirect: redirect, state: "expected"), "good")
        for suffix in ["?state=wrong&code=good", "?state=expected&state=expected&code=good", "?state=expected&code=a&code=b", "?state=expected&error=access_denied"] {
            XCTAssertThrowsError(try GoogleOAuth.code(from: URL(string: redirect.absoluteString + suffix)!, redirect: redirect, state: "expected"))
        }
        XCTAssertThrowsError(try GoogleOAuth.code(from: URL(string: "http://example.test:12345/oauth2callback?state=expected&code=good")!, redirect: redirect, state: "expected"))
        XCTAssertEqual(try GoogleOAuthConfiguration.imported(credentials).clientID, "synthetic-client.apps.googleusercontent.com")
        XCTAssertThrowsError(try GoogleOAuthConfiguration.imported(Data(#"{"web":{"client_id":"synthetic.apps.googleusercontent.com"}}"#.utf8)))
    }
    func testProductionLoopbackCallback() async throws {
        let authorizer = GoogleBrowserAuthorizer { authURL in
            let query = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = URL(string: query.first { $0.name == "redirect_uri" }!.value!)!
            let state = query.first { $0.name == "state" }!.value!
            let invalid = URL(string: redirect.absoluteString + "?state=forged&code=bad")!
            let (_, rejected) = try! await URLSession.shared.data(from: invalid)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
            var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
            callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "loopback-synthetic")]
            let (_, accepted) = try! await URLSession.shared.data(from: callback.url!)
            XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
            return true
        }
        let code = try await authorizer.authorize(configuration: GoogleOAuthConfiguration(clientID: "synthetic"))
        XCTAssertEqual(code.code, "loopback-synthetic"); XCTAssertEqual(code.redirect.host, "127.0.0.1")
        XCTAssertEqual(code.verifier.count, 43)
    }
    func testProductionLoopbackCancellation() async throws {
        let opened = BrowserOpened()
        let authorizer = GoogleBrowserAuthorizer { _ in await opened.mark(); return true }
        let pending = Task { try await authorizer.authorize(configuration: GoogleOAuthConfiguration(clientID: "synthetic")) }
        while !(await opened.value) { await Task.yield() }
        await authorizer.cancel()
        do { _ = try await pending.value; XCTAssertTrue(false) } catch GoogleCalendarError.cancelled {}
    }
    func testTokensRestartRefreshAndRevocation() async throws {
        let storage = GoogleMemoryStore(), session = session(), authorizer = GoogleAuthStub()
        let oauth = GoogleOAuthClient(storage: storage, authorizer: authorizer, session: session)
        try await oauth.configure(credentials)
        GoogleHTTPStub.handle = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            let form = body(request)
            XCTAssertEqual(form["grant_type"], "authorization_code"); XCTAssertEqual(form["code"], "synthetic-code+&")
            XCTAssertEqual(form["code_verifier"], "synthetic-verifier")
            return (200, token())
        }
        try await oauth.signIn()
        XCTAssertTrue(await oauth.authorized())
        let restarted = GoogleOAuthClient(storage: storage, authorizer: authorizer, session: session)
        XCTAssertEqual(try await restarted.accessToken(), "first-access")
        GoogleHTTPStub.handle = { request in
            let form = body(request)
            XCTAssertEqual(form["grant_type"], "refresh_token"); XCTAssertEqual(form["refresh_token"], "synthetic-refresh")
            return (200, token("refreshed-access", refresh: false, scopes: nil))
        }
        XCTAssertEqual(try await restarted.accessToken(rejected: "first-access"), "refreshed-access")
        let again = GoogleOAuthClient(storage: storage, authorizer: authorizer, session: session)
        XCTAssertEqual(try await again.accessToken(), "refreshed-access")
        GoogleHTTPStub.handle = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do { _ = try await again.accessToken(rejected: "refreshed-access"); XCTAssertTrue(false) } catch GoogleCalendarError.signedOut {}
        XCTAssertFalse(await again.authorized()); XCTAssertTrue(storage.read("tokens") == nil)
        XCTAssertTrue(try await again.configuration() != nil)
    }
    func testDeniedScopesAndCancelledSignIn() async throws {
        let storage = GoogleMemoryStore(), authorizer = GoogleAuthStub()
        let oauth = GoogleOAuthClient(storage: storage, authorizer: authorizer, session: session())
        try await oauth.configure(credentials)
        GoogleHTTPStub.handle = { _ in (200, token(scopes: GoogleOAuth.scopes[0])) }
        do { try await oauth.signIn(); XCTAssertTrue(false) } catch GoogleCalendarError.consent {}
        XCTAssertFalse(await oauth.authorized()); XCTAssertTrue(storage.read("tokens") == nil)
        await authorizer.suspend()
        let pending = Task { try await oauth.signIn() }
        while !(await authorizer.waiting()) { await Task.yield() }
        try await oauth.disconnect()
        do { try await pending.value; XCTAssertTrue(false) } catch GoogleCalendarError.cancelled {}
        XCTAssertFalse(await oauth.authorized()); XCTAssertTrue(storage.read("tokens") == nil)
    }
    func testConcurrentRefreshUsesOneExchange() async throws {
        let oauth = GoogleOAuthClient(storage: GoogleMemoryStore(), authorizer: GoogleAuthStub(), session: session())
        try await oauth.configure(credentials)
        GoogleHTTPStub.handle = { _ in (200, token()) }; try await oauth.signIn()
        var refreshes = 0
        GoogleHTTPStub.handle = { request in
            refreshes += 1
            XCTAssertEqual(body(request)["grant_type"], "refresh_token")
            return (200, token("shared-refresh", refresh: false, scopes: nil))
        }
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await oauth.accessToken(rejected: "first-access") } }
            for try await access in group { XCTAssertEqual(access, "shared-refresh") }
        }
        XCTAssertEqual(refreshes, 1)
    }
    func testDirectAPIPaginationRecurrenceDSTAndSelection() async throws {
        let session = session(), oauth = GoogleOAuthClient(storage: GoogleMemoryStore(), authorizer: GoogleAuthStub(), session: session)
        try await oauth.configure(credentials)
        GoogleHTTPStub.handle = { _ in (200, token()) }; try await oauth.signIn()
        let provider = GoogleCalendarProvider(oauth: oauth, session: session)
        var listReads = 0, eventReads = 0
        GoogleHTTPStub.handle = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.host, "www.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer first-access")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url!.path.hasSuffix("calendarList") {
                listReads += 1
                if listReads == 1 { return (200, Data(#"{"kind":"calendar#calendarList","items":[{"id":"work/user@example.com","summary":"Work","primary":true,"timeZone":"America/Toronto"}],"nextPageToken":"list-two"}"#.utf8)) }
                XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "list-two")
                return (200, Data(#"{"kind":"calendar#calendarList","items":[{"id":"unselected","summary":"Private"}]}"#.utf8))
            }
            eventReads += 1
            XCTAssertTrue(request.url!.absoluteString.contains("work%2Fuser%40example.com/events"))
            XCTAssertEqual(query.first { $0.name == "singleEvents" }?.value, "true")
            XCTAssertEqual(query.first { $0.name == "timeMin" }?.value, "2026-11-01T04:00:00Z")
            XCTAssertEqual(query.first { $0.name == "timeMax" }?.value, "2026-11-02T05:00:00Z")
            if eventReads == 1 {
                return (200, Data(#"{"kind":"calendar#events","timeZone":"America/Toronto","nextPageToken":"events-two","items":[{"id":"day","summary":"All day","start":{"date":"2026-11-01"},"end":{"date":"2026-11-02"}},{"id":"repeat","start":{"dateTime":"2026-11-01T10:00:00-05:00"},"end":{"dateTime":"2026-11-01T11:00:00-05:00"}},{"id":"cancelled","status":"cancelled"}]}"#.utf8))
            }
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "events-two")
            return (200, Data(#"{"kind":"calendar#events","timeZone":"America/Toronto","items":[{"id":"repeat","start":{"dateTime":"2026-11-01T13:00:00.000-05:00"},"end":{"dateTime":"2026-11-01T13:30:00-05:00"}},{"id":"free","transparency":"transparent","start":{"dateTime":"2026-11-01T14:00:00-05:00"},"end":{"dateTime":"2026-11-01T14:30:00-05:00"}},{"id":"declined","attendees":[{"self":true,"responseStatus":"declined"}],"start":{"dateTime":"2026-11-01T15:00:00-05:00"},"end":{"dateTime":"2026-11-01T15:30:00-05:00"}}]}"#.utf8))
        }
        let calendars = try await provider.calendars(refresh: true)
        XCTAssertEqual(calendars.count, 2)
        let iso = ISO8601DateFormatter(), interval = DateInterval(start: iso.date(from: "2026-11-01T04:00:00Z")!, end: iso.date(from: "2026-11-02T05:00:00Z")!)
        let events = try await provider.occurrences(in: interval, calendarIDs: ["work/user@example.com"])
        XCTAssertEqual(events.count, 5); XCTAssertEqual(Set(events.map(\.id)).count, 5)
        XCTAssertEqual(events.filter(\.busy).count, 3); XCTAssertEqual(events.first { $0.allDay }?.end.timeIntervalSince(events.first { $0.allDay }!.start), 25 * 3600)
        XCTAssertEqual(listReads, 2); XCTAssertEqual(eventReads, 2)
        do { _ = try await provider.occurrences(in: interval, calendarIDs: []); XCTAssertTrue(false) } catch CalendarConnectionError.selectCalendars {}
        XCTAssertEqual(eventReads, 2)
    }
    func testUnauthorizedRetryAndAPIFailuresStayVisible() async throws {
        let session = session(), oauth = GoogleOAuthClient(storage: GoogleMemoryStore(), authorizer: GoogleAuthStub(), session: session)
        try await oauth.configure(credentials)
        GoogleHTTPStub.handle = { _ in (200, token()) }; try await oauth.signIn()
        let provider = GoogleCalendarProvider(oauth: oauth, session: session)
        var requests = 0, refreshes = 0
        GoogleHTTPStub.handle = { request in
            if request.url?.host == "oauth2.googleapis.com" { refreshes += 1; return (200, token("new-access", refresh: false, scopes: nil)) }
            requests += 1
            if requests == 1 { return (401, Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, Data(#"{"kind":"calendar#calendarList","items":[]}"#.utf8))
        }
        XCTAssertEqual(try await provider.calendars(refresh: true).count, 0)
        XCTAssertEqual(requests, 2); XCTAssertEqual(refreshes, 1)
        GoogleHTTPStub.handle = { _ in (403, Data(#"{"error":{"message":"synthetic"}}"#.utf8)) }
        do { _ = try await provider.calendars(refresh: true); XCTAssertTrue(false) } catch GoogleCalendarError.api(403) {}
        GoogleHTTPStub.handle = { _ in (200, Data(#"{}"#.utf8)) }
        do { _ = try await provider.calendars(refresh: true); XCTAssertTrue(false) } catch GoogleCalendarError.invalidResponse {}
        GoogleHTTPStub.handle = { request in request.url?.host == "oauth2.googleapis.com" ? (200, token("still-rejected", refresh: false, scopes: nil)) : (401, Data()) }
        do { _ = try await provider.calendars(refresh: true); XCTAssertTrue(false) } catch GoogleCalendarError.signedOut {}
        XCTAssertEqual(await provider.access(), .notDetermined)
    }
    @MainActor func testOldMacOSConnectionDoesNotMigrate() {
        let name = "google-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "calendar.enabled"); defaults.set(["icloud-private"], forKey: "calendar.selectedIDs")
        let connection = CalendarConnection(defaults: defaults)
        XCTAssertFalse(connection.enabled); XCTAssertTrue(connection.selectedIDs.isEmpty)
    }
}
