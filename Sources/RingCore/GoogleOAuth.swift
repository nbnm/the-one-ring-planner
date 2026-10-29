import Foundation
import Security
import CryptoKit

public enum GoogleCalendarError: LocalizedError {
    case configuration, credentials, signedOut, consent, publishingPermission, offlineAuthorization, cancelled, timeout, callback, invalidResponse, keychain, api(Int)
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Import the JSON credentials for a Google Cloud Desktop app OAuth client. Enable the Google Calendar API in that project first."
        case .credentials: return "Google rejected this OAuth client. Check that it is a Desktop app client and import its downloaded JSON again."
        case .signedOut: return "Sign in with Google again. The saved Google authorization is missing or expired."
        case .consent: return "Google Calendar read access was not granted. Sign in again and allow both calendar permissions."
        case .publishingPermission: return "Enable calendar writing in Settings → Google Calendar to publish confirmed tasks and routines. Your existing read connection is still available."
        case .offlineAuthorization: return "Google did not return offline access. Authorize again; your previous connection has been kept."
        case .cancelled: return "Google sign-in was cancelled."
        case .timeout: return "Google sign-in timed out. Try signing in again."
        case .callback: return "The Google sign-in response could not be verified. Start a new sign-in."
        case .invalidResponse: return "Google returned an incomplete calendar response. Refresh and try again."
        case .keychain: return "Google credentials could not be read or saved in macOS Keychain. Allow the app to access its Keychain entries and try again."
        case .api(403): return "Google Calendar access was refused. Enable the Calendar API in the OAuth project, check your Workspace policy, and allow the requested calendar permissions."
        case .api(404): return "A selected Google calendar is unavailable. Refresh and update the calendar selection."
        case .api(429): return "Google is limiting calendar requests. Wait a moment, then refresh."
        case .api(let status): return "Google Calendar could not be reached (HTTP \(status)). Refresh and try again."
        }
    }
}

public struct GoogleOAuthConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
    public static func imported(_ data: Data) throws -> Self {
        struct Download: Decodable {
            struct Installed: Decodable { let client_id: String; let client_secret: String? }
            let installed: Installed
        }
        guard data.count <= 65_536, let download = try? JSONDecoder().decode(Download.self, from: data) else { throw GoogleCalendarError.configuration }
        let id = download.installed.client_id
        guard id.range(of: #"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil else { throw GoogleCalendarError.configuration }
        return Self(clientID: id, clientSecret: download.installed.client_secret)
    }
}

public enum GoogleOAuth {
    public static let scopes = ["https://www.googleapis.com/auth/calendar.calendarlist.readonly", "https://www.googleapis.com/auth/calendar.events.readonly"]
    public static let publishingScope = "https://www.googleapis.com/auth/calendar.events.owned"
    public static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleCalendarError.callback }
        return base64URL(Data(bytes))
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func authorizationURL(clientID: String, redirect: URL, state: String, verifier: String, requestedScopes: [String] = scopes) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirect.absoluteString, "response_type": "code", "scope": requestedScopes.joined(separator: " "),
                          "state": state, "code_challenge": challenge(verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    public static func code(from url: URL, redirect: URL, state: String) throws -> String {
        guard url.scheme == redirect.scheme, url.host == "127.0.0.1", url.port == redirect.port, url.path == redirect.path,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), url.fragment == nil else { throw GoogleCalendarError.callback }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state else { throw GoogleCalendarError.callback }
        if items.contains(where: { $0.name == "error" }) { throw GoogleCalendarError.consent }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count < 8192 else { throw GoogleCalendarError.callback }
        return code
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
}

public protocol GoogleCredentialStoring: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, name: String) throws
    func remove(_ name: String) throws
}

public struct GoogleKeychainStore: GoogleCredentialStoring {
    private let service: String
    public init(service: String = "com.t1a.the-one-ring-planner.google-direct") { self.service = service }
    private func query(_ name: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name] }
    public func read(_ name: String) throws -> Data? {
        var query = query(name); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw GoogleCalendarError.keychain }
        return data
    }
    public func write(_ data: Data, name: String) throws {
        let query = query(name)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data; entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GoogleCalendarError.keychain }
    }
    public func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleCalendarError.keychain }
    }
}

public protocol GoogleAuthorizing: Sendable {
    func authorize(configuration: GoogleOAuthConfiguration, requestedScopes: [String]) async throws -> GoogleAuthorizationCode
    func cancel() async
}
public extension GoogleAuthorizing {
    func authorize(configuration: GoogleOAuthConfiguration) async throws -> GoogleAuthorizationCode { try await authorize(configuration: configuration, requestedScopes: GoogleOAuth.scopes) }
}
public struct GoogleAuthorizationCode: Sendable {
    public let code: String
    public let redirect: URL
    public let verifier: String
    public init(code: String, redirect: URL, verifier: String) { self.code = code; self.redirect = redirect; self.verifier = verifier }
}

private final class GoogleRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum GoogleHTTP {
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: GoogleRedirectPolicy(), delegateQueue: nil)
    }
}

private struct GoogleTokens: Codable, Sendable {
    let clientID: String
    let access: String
    let refresh: String
    let expires: Date
    let scopes: Set<String>
}

public actor GoogleOAuthClient {
    private let storage: any GoogleCredentialStoring
    private let authorizer: any GoogleAuthorizing
    private let session: URLSession
    private var version = UUID()
    private var refreshTask: Task<GoogleTokens, Error>?
    public init(storage: any GoogleCredentialStoring = GoogleKeychainStore(), authorizer: any GoogleAuthorizing = GoogleBrowserAuthorizer(), session: URLSession = GoogleHTTP.session()) {
        self.storage = storage; self.authorizer = authorizer; self.session = session
    }
    public func configuration() throws -> GoogleOAuthConfiguration? {
        guard let data = try storage.read("client") else { return nil }
        return try JSONDecoder().decode(GoogleOAuthConfiguration.self, from: data)
    }
    public func configure(_ data: Data) async throws {
        let config = try GoogleOAuthConfiguration.imported(data)
        version = UUID(); refreshTask?.cancel(); refreshTask = nil
        try storage.remove("tokens")
        try storage.write(JSONEncoder().encode(config), name: "client")
        await authorizer.cancel()
    }
    private func tokens() throws -> GoogleTokens? {
        guard let data = try storage.read("tokens"), let config = try configuration() else { return nil }
        let tokens = try JSONDecoder().decode(GoogleTokens.self, from: data)
        return tokens.clientID == config.clientID && Set(GoogleOAuth.scopes).isSubset(of: tokens.scopes) ? tokens : nil
    }
    public func authorized() -> Bool { (try? tokens()) != nil }
    public func publishingAuthorized() -> Bool { (try? tokens())?.scopes.contains(GoogleOAuth.publishingScope) == true }
    public func signIn(publishing: Bool = false) async throws {
        guard let config = try configuration() else { throw GoogleCalendarError.configuration }
        let generation = UUID(); version = generation
        refreshTask?.cancel(); refreshTask = nil
        await authorizer.cancel()
        guard generation == version else { throw GoogleCalendarError.cancelled }
        let requested = GoogleOAuth.scopes + (publishing ? [GoogleOAuth.publishingScope] : [])
        let code = try await authorizer.authorize(configuration: config, requestedScopes: requested)
        guard generation == version else { throw GoogleCalendarError.cancelled }
        var fields = ["grant_type": "authorization_code", "client_id": config.clientID, "code": code.code, "redirect_uri": code.redirect.absoluteString, "code_verifier": code.verifier]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        // A new consent flow can choose another account. Never attach an old
        // account's refresh token to a new account's access token.
        let tokens = try await exchange(fields, clientID: config.clientID, previous: nil)
        if publishing && !tokens.scopes.contains(GoogleOAuth.publishingScope) { throw GoogleCalendarError.publishingPermission }
        guard generation == version else { throw GoogleCalendarError.cancelled }
        try storage.write(JSONEncoder().encode(tokens), name: "tokens")
    }
    public func cancel() async {
        version = UUID(); refreshTask?.cancel(); refreshTask = nil
        await authorizer.cancel()
    }
    public func disconnect() async throws {
        version = UUID(); refreshTask?.cancel(); refreshTask = nil
        try storage.remove("tokens")
        await authorizer.cancel()
    }
    public func accessToken(rejected: String? = nil, publishing: Bool = false) async throws -> String {
        guard let config = try configuration(), let saved = try tokens() else { throw GoogleCalendarError.signedOut }
        if publishing && !saved.scopes.contains(GoogleOAuth.publishingScope) { throw GoogleCalendarError.publishingPermission }
        if saved.expires > Date().addingTimeInterval(60), rejected != saved.access { return saved.access }
        let generation = version
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard generation == version else { throw GoogleCalendarError.cancelled }
            if publishing && !refreshed.scopes.contains(GoogleOAuth.publishingScope) { throw GoogleCalendarError.publishingPermission }
            return refreshed.access
        }
        let task = Task { [self] in
            var fields = ["grant_type": "refresh_token", "client_id": config.clientID, "refresh_token": saved.refresh]
            if let secret = config.clientSecret { fields["client_secret"] = secret }
            return try await exchange(fields, clientID: config.clientID, previous: saved)
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            guard generation == version else { throw GoogleCalendarError.cancelled }
            try storage.write(JSONEncoder().encode(refreshed), name: "tokens")
            refreshTask = nil
            if publishing && !refreshed.scopes.contains(GoogleOAuth.publishingScope) { throw GoogleCalendarError.publishingPermission }
            return refreshed.access
        } catch {
            if generation == version {
                refreshTask = nil
                if case GoogleCalendarError.signedOut = error { try storage.remove("tokens") }
            }
            throw error
        }
    }
    private func exchange(_ fields: [String: String], clientID: String, previous: GoogleTokens?) async throws -> GoogleTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.httpBody = GoogleOAuth.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            if code == "invalid_grant" { throw GoogleCalendarError.signedOut }
            if code == "invalid_client" || code == "unauthorized_client" { throw GoogleCalendarError.credentials }
            throw GoogleCalendarError.api(response.statusCode)
        }
        struct Reply: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String?; let token_type: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty, reply.expires_in > 0 else { throw GoogleCalendarError.invalidResponse }
        let scopes = reply.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        guard Set(GoogleOAuth.scopes).isSubset(of: scopes) else { throw GoogleCalendarError.consent }
        guard let refresh = reply.refresh_token ?? previous?.refresh, !refresh.isEmpty else { throw GoogleCalendarError.offlineAuthorization }
        return GoogleTokens(clientID: clientID, access: reply.access_token, refresh: refresh, expires: Date().addingTimeInterval(reply.expires_in), scopes: scopes)
    }
}
