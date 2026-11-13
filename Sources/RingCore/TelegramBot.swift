import Foundation

public enum TelegramBotError: LocalizedError {
    case configuration(String), http(Int, Int?), invalidResponse, network
    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .http(401, _): return "Telegram rejected the bot token. Replace it in Telegram settings."
        case .http(409, _): return "Another poller or webhook is using this bot. Stop it, then reconnect."
        case .http(429, let seconds): return "Telegram rate limit. Retrying after \(seconds ?? 60) seconds."
        case .http(let status, _): return "Telegram request failed (HTTP \(status)). Saved messages remain available for retry."
        case .invalidResponse: return "Telegram returned an invalid response. Polling will retry."
        case .network: return "Telegram could not be reached. Check your connection; polling will retry."
        }
    }
    public var retryAfter: Int { if case .http(429, let seconds) = self { return max(1, min(3600, seconds ?? 60)) }; return 30 }
}
public struct TelegramUser: Codable, Equatable, Sendable { public var id: Int64; public var is_bot: Bool?; public var username: String?; public var first_name: String? }
public struct TelegramChat: Codable, Equatable, Sendable { public var id: Int64; public var type: String }
public struct TelegramMedia: Codable, Equatable, Sendable {
    public var file_id: String
    public var file_unique_id: String?
    public var file_size: Int?
    public var file_name: String?
    public var mime_type: String?
    public var duration: Int?
}
public struct TelegramMessage: Codable, Equatable, Sendable {
    public var message_id: Int64
    public var date: Int64
    public var from: TelegramUser?
    public var chat: TelegramChat
    public var text: String?
    public var caption: String?
    public var photo: [TelegramMedia]?
    public var document: TelegramMedia?
    public var voice: TelegramMedia?
    public var audio: TelegramMedia?
    public var video: TelegramMedia?
    public var video_note: TelegramMedia?
    public var animation: TelegramMedia?
    public var sticker: TelegramMedia?
    public var media_group_id: String?
    public var location: TelegramLocation?
    public var contact: TelegramContact?
    public var poll: TelegramPoll?
    public struct TelegramLocation: Codable, Equatable, Sendable { public var latitude: Double; public var longitude: Double }
    public struct TelegramContact: Codable, Equatable, Sendable { public var phone_number: String; public var first_name: String; public var last_name: String? }
    public struct TelegramPoll: Codable, Equatable, Sendable { public var question: String }
    public var content: String {
        if let text { return text }; if let caption, !caption.isEmpty { return caption }
        if let location { return "Location: \(location.latitude), \(location.longitude)" }
        if let contact { return [contact.first_name, contact.last_name ?? "", contact.phone_number].filter { !$0.isEmpty }.joined(separator: " ") }
        if let poll { return poll.question }
        return media.map { isAudio ? "Voice or audio recording" : ($0.file_name ?? "Telegram attachment") } ?? "Telegram message"
    }
    public var media: TelegramMedia? { voice ?? audio ?? document ?? video ?? video_note ?? animation ?? sticker ?? photo?.last }
    public var isAudio: Bool { voice != nil || audio != nil || (document?.mime_type?.hasPrefix("audio/") == true) }
    public func belongs(to owner: Int64) -> Bool { chat.type == "private" && chat.id == owner && from?.id == owner && from?.is_bot != true }
}
public struct TelegramUpdate: Codable, Equatable, Sendable { public var update_id: Int64; public var message: TelegramMessage? }
private final class TelegramRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct TelegramBotClient: @unchecked Sendable {
    private struct Failure: Decodable { struct Parameters: Decodable { let retry_after: Int? }; let ok: Bool; let error_code: Int?; let parameters: Parameters? }
    private let token: String
    private let session: URLSession
    public init(token: String, session: URLSession? = nil) throws {
        guard token.range(of: "^[0-9]+:[A-Za-z0-9_-]{20,}$", options: .regularExpression) != nil else { throw TelegramBotError.configuration("Enter the bot token supplied by @BotFather.") }
        self.token = token
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config, delegate: TelegramRedirectPolicy(), delegateQueue: nil)
        }
    }
    private func call<T: Decodable>(_ method: String, body: [String: Any] = [:], as type: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await result(request, as: type)
    }
    private func result<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { if Task.isCancelled { throw CancellationError() }; throw TelegramBotError.network }
        guard data.count <= 8 * 1024 * 1024, let http = response as? HTTPURLResponse else { throw TelegramBotError.invalidResponse }
        guard let status = try? JSONDecoder().decode(Failure.self, from: data) else { throw TelegramBotError.invalidResponse }
        guard status.ok, (200..<300).contains(http.statusCode) else { throw TelegramBotError.http(status.error_code ?? http.statusCode, status.parameters?.retry_after) }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = value["result"], let result = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]), let decoded = try? JSONDecoder().decode(T.self, from: result) else { throw TelegramBotError.invalidResponse }
        return decoded
    }
    public func applyIdentity(avatarJPEG: Data) async throws -> TelegramIdentityResult {
        guard avatarJPEG.starts(with: [0xff, 0xd8, 0xff]), avatarJPEG.count <= 5 * 1024 * 1024 else { throw TelegramBotError.configuration("Use a JPEG bot avatar smaller than 5 MB.") }
        let me = try await me()
        for language in ["", "en", "ru"] {
            let _: Bool = try await call("setMyName", body: ["name": TelegramIdentity.name, "language_code": language], as: Bool.self)
            let _: Bool = try await call("setMyShortDescription", body: ["short_description": TelegramIdentity.shortDescription(language: language), "language_code": language], as: Bool.self)
            let _: Bool = try await call("setMyDescription", body: ["description": TelegramIdentity.description(language: language), "language_code": language], as: Bool.self)
        }
        let boundary = "ring-profile-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"\r\n\r\n{\"type\":\"static\",\"photo\":\"attach://avatar\"}\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"one-ring-planner.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(avatarJPEG); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/setMyProfilePhoto")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let _: Bool = try await result(request, as: Bool.self)
        struct Name: Decodable { let name: String }
        struct Short: Decodable { let short_description: String }
        struct About: Decodable { let description: String }
        struct Photos: Decodable { let total_count: Int; let photos: [[TelegramMedia]] }
        let name = try await call("getMyName", as: Name.self).name
        let short = try await call("getMyShortDescription", as: Short.self).short_description
        let about = try await call("getMyDescription", as: About.self).description
        let photos = try await call("getUserProfilePhotos", body: ["user_id": me.id, "limit": 1], as: Photos.self)
        guard name == TelegramIdentity.name, short == TelegramIdentity.shortDescription(), about == TelegramIdentity.description(), let photo = photos.photos.first?.last, photos.total_count > 0 else { throw TelegramBotError.configuration("Telegram has not confirmed every profile change. Retry Update bot profile.") }
        return TelegramIdentityResult(name: name, shortDescription: short, description: about, photoFileID: photo.file_id)
    }
    public func me() async throws -> TelegramUser { try await call("getMe", as: TelegramUser.self) }
    public func webhookConfigured() async throws -> Bool { struct Webhook: Decodable { let url: String }; return try await call("getWebhookInfo", as: Webhook.self).url.isEmpty == false }
    public func removeWebhook() async throws { let _: Bool = try await call("deleteWebhook", body: ["drop_pending_updates": false], as: Bool.self) }
    public func updates(offset: Int64) async throws -> [TelegramUpdate] {
        let updates = try await call("getUpdates", body: ["offset": offset, "limit": 100, "timeout": 0, "allowed_updates": ["message"]], as: [TelegramUpdate].self)
        guard updates.count <= 100, updates.allSatisfy({ $0.update_id >= 0 && $0.update_id < Int64.max }) else { throw TelegramBotError.invalidResponse }
        return updates.sorted { $0.update_id < $1.update_id }
    }
    public func send(chatID: Int64, text: String) async throws {
        struct Sent: Decodable { let message_id: Int64 }
        let _: Sent = try await call("sendMessage", body: ["chat_id": chatID, "text": TelegramMessageStyle.html(text), "parse_mode": "HTML", "link_preview_options": ["is_disabled": true], "protect_content": true], as: Sent.self)
    }
    public func setCommands() async throws {
        let commands = [("help", "Commands"), ("today", "Today's plan"), ("tomorrow", "Tomorrow's plan"), ("next", "Next task"), ("tasks", "Active tasks"), ("work", "Work tasks"), ("personal", "Personal tasks"), ("task", "Task details by ID"), ("inbox", "Inbox items"), ("find", "Find a task"), ("status", "Connection and pending captures")]
        let _: Bool = try await call("setMyCommands", body: ["commands": commands.map { ["command": $0.0, "description": $0.1] }, "scope": ["type": "all_private_chats"]], as: Bool.self)
    }
    public func download(_ media: TelegramMedia) async throws -> (Data, String) {
        guard media.file_size.map({ $0 > 0 && $0 <= LibraryPolicy.maximumAttachmentBytes }) ?? true else { throw TelegramBotError.configuration("Telegram downloads are limited to 20 MB. The message is kept; send a smaller file or a link.") }
        struct File: Decodable { let file_path: String?; let file_size: Int? }
        let file = try await call("getFile", body: ["file_id": media.file_id], as: File.self)
        guard let path = file.file_path, !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"), path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil, file.file_size.map({ $0 <= LibraryPolicy.maximumAttachmentBytes }) ?? true else { throw TelegramBotError.invalidResponse }
        var request = URLRequest(url: URL(string: "https://api.telegram.org/file/bot\(token)/\(path)")!); request.timeoutInterval = 90
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { if Task.isCancelled { throw CancellationError() }; throw TelegramBotError.network }
        guard let status = response as? HTTPURLResponse else { throw TelegramBotError.invalidResponse }
        guard status.statusCode == 200 else { throw TelegramBotError.http(status.statusCode, nil) }
        guard !data.isEmpty, data.count <= LibraryPolicy.maximumAttachmentBytes, file.file_size.map({ $0 == data.count }) ?? true else { throw TelegramBotError.configuration("Telegram file is incomplete or exceeds 20 MB. Retry or send a smaller file.") }
        return (data, path)
    }
}
