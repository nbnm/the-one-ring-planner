import Foundation

public actor GoogleCalendarProvider: CalendarProviding {
    public let oauth: GoogleOAuthClient
    let session: URLSession
    var version = UUID()
    private let workspaceID: String?
    private var choices: [GoogleCalendarListEntry] = []
    public init(oauth: GoogleOAuthClient = GoogleOAuthClient(), session: URLSession = GoogleHTTP.session(), workspaceID: String? = nil) { self.oauth = oauth; self.session = session; self.workspaceID = workspaceID }
    public func access() async -> CalendarAccess { await oauth.authorized() ? .full : .notDetermined }
    public func requestAccess() async throws -> Bool {
        version = UUID(); choices = []
        try await oauth.signIn()
        return true
    }
    public func cancelAuthorization() async { await oauth.cancel() }
    public func disconnect() async throws {
        version = UUID(); choices = []
        try await oauth.disconnect()
    }
    public func configure(_ data: Data) async throws {
        _ = try GoogleOAuthConfiguration.imported(data)
        version = UUID(); choices = []
        try await oauth.configure(data)
    }
    public func clientID() async throws -> String? { try await oauth.configuration()?.clientID }
    func calendarAccountID() -> String? { choices.first { $0.primary == true }?.id }
    public func publicationDestinations(refresh: Bool = false) async throws -> [PublicationDestination] {
        if refresh || choices.isEmpty { _ = try await calendars(refresh: true) }
        guard let primary = choices.first(where: { $0.primary == true }) else { throw CalendarPublicationError.destination }
        return choices.filter { $0.accessRole == "owner" }.map {
            PublicationDestination(id: $0.id, title: $0.summaryOverride ?? $0.summary ?? $0.id, accountID: primary.id, primary: $0.primary == true)
        }.sorted { $0.primary != $1.primary ? $0.primary : $0.title < $1.title }
    }
    public func enablePublishing() async throws {
        try await oauth.signIn(publishing: true)
        version = UUID(); choices = []
    }
    public func calendars(refresh: Bool) async throws -> [CalendarDescriptor] {
        if !refresh && !choices.isEmpty { return descriptors() }
        let generation = version
        var items: [GoogleCalendarListEntry] = [], token: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "showHidden", value: "true"), URLQueryItem(name: "minAccessRole", value: "reader")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page: GoogleCalendarList = try await get(path: "/calendar/v3/users/me/calendarList", query: query)
            guard generation == version else { throw GoogleCalendarError.cancelled }
            guard page.kind == "calendar#calendarList" else { throw GoogleCalendarError.invalidResponse }
            items += (page.items ?? []).filter { $0.deleted != true }
            token = page.nextPageToken
            if let token { guard !token.isEmpty, seen.insert(token).inserted, seen.count <= 100 else { throw GoogleCalendarError.invalidResponse } }
        } while token != nil
        var ids = Set<String>()
        choices = items.filter { ids.insert($0.id).inserted }
        return descriptors()
    }
    private func descriptors() -> [CalendarDescriptor] {
        let account = choices.first(where: { $0.primary == true })?.id ?? "Google"
        return choices.map { CalendarDescriptor(id: $0.id, title: $0.summaryOverride ?? $0.summary ?? $0.id, account: account) }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
    public func occurrences(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [CalendarOccurrence] {
        guard interval.duration > 0, interval.duration < 32 * 86400 else { throw CalendarConnectionError.invalidRange }
        guard !calendarIDs.isEmpty else { throw CalendarConnectionError.selectCalendars }
        let generation = version, calendars = choices.filter { calendarIDs.contains($0.id) }
        guard Set(calendars.map(\.id)) == calendarIDs else { throw CalendarConnectionError.missingCalendars }
        var events: [CalendarOccurrence] = []
        let formatter = ISO8601DateFormatter()
        for calendar in calendars.sorted(by: { $0.id < $1.id }) {
            var token: String?, seen = Set<String>()
            repeat {
                var query = [URLQueryItem(name: "timeMin", value: formatter.string(from: interval.start)), URLQueryItem(name: "timeMax", value: formatter.string(from: interval.end)),
                             URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"), URLQueryItem(name: "maxResults", value: "2500"), URLQueryItem(name: "showDeleted", value: "false")]
                if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
                let id = calendar.id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
                let page: GoogleEventsPage = try await get(path: "/calendar/v3/calendars/\(id)/events", query: query)
                guard generation == version else { throw GoogleCalendarError.cancelled }
                guard page.kind == "calendar#events" else { throw GoogleCalendarError.invalidResponse }
                for event in page.items ?? [] where event.status != "cancelled" {
                    let occurrence = try event.occurrence(calendarID: calendar.id, title: calendar.summaryOverride ?? calendar.summary ?? calendar.id, timeZone: page.timeZone ?? calendar.timeZone, workspaceID: workspaceID)
                    if occurrence.start < interval.end && occurrence.end > interval.start { events.append(occurrence) }
                }
                token = page.nextPageToken
                if let token { guard !token.isEmpty, seen.insert(token).inserted, seen.count <= 100 else { throw GoogleCalendarError.invalidResponse } }
            } while token != nil
        }
        return events.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        let generation = version
        var url = URLComponents(string: "https://www.googleapis.com")!; url.percentEncodedPath = path; url.queryItems = query
        var token = try await oauth.accessToken()
        for attempt in 0...1 {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            var request = URLRequest(url: url.url!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard generation == version else { throw GoogleCalendarError.cancelled }
            guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            if response.statusCode == 401 {
                if attempt == 0 { token = try await oauth.accessToken(rejected: token); continue }
                try await oauth.disconnect(); throw GoogleCalendarError.signedOut
            }
            guard response.statusCode == 200 else { throw GoogleCalendarError.api(response.statusCode) }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw GoogleCalendarError.invalidResponse }
            return value
        }
        throw GoogleCalendarError.signedOut
    }
}

private struct GoogleCalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let timeZone: String?
    let primary: Bool?
    let deleted: Bool?
    let accessRole: String?
}
private struct GoogleCalendarList: Decodable { let kind: String; let items: [GoogleCalendarListEntry]?; let nextPageToken: String? }
private struct GoogleEventsPage: Decodable { let kind: String; let items: [GoogleEvent]?; let nextPageToken: String?; let timeZone: String? }
private struct GoogleEvent: Decodable {
    struct EventDate: Decodable { let date: String?; let dateTime: String?; let timeZone: String? }
    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    }
    let id: String
    let summary: String?
    let colorId: String?
    let status: String?
    let transparency: String?
    let eventType: String?
    let attendees: [Attendee]?
    let start: EventDate?
    let end: EventDate?
    let extendedProperties: [String: [String: String]]?
    func occurrence(calendarID: String, title: String, timeZone: String?, workspaceID: String?) throws -> CalendarOccurrence {
        guard let start, let end, (start.date != nil) == (end.date != nil) else { throw GoogleCalendarError.invalidResponse }
        let begin = try Self.date(start, fallbackZone: timeZone), finish = try Self.date(end, fallbackZone: timeZone)
        guard begin < finish else { throw GoogleCalendarError.invalidResponse }
        let declined = attendees?.contains { $0.isSelf == true && $0.responseStatus == "declined" } ?? false
        let properties = extendedProperties?["private"] ?? [:]
        let owned = CalendarPlanEvent.isOwned(eventID: id, metadata: properties, workspaceID: workspaceID)
        return CalendarOccurrence(id: id, calendarID: calendarID, title: summary?.isEmpty == false ? summary! : "Busy", calendarTitle: title,
                                  start: begin, end: finish, allDay: start.date != nil, busy: transparency != "transparent" && !declined && eventType != "workingLocation",
                                  managedByPlanner: owned, plannerCategory: owned ? (properties["ringRoutine"] == nil ? .task : .routine) : nil, colorID: colorId,
                                  plannerTaskID: owned ? properties["ringTask"] : nil, plannerRoutineID: owned ? properties["ringRoutine"] : nil, plannerBlockID: owned ? properties["ringBlock"] : nil, plannerDay: owned ? properties["ringDay"] : nil)
    }
    private static func date(_ value: EventDate, fallbackZone: String?) throws -> Date {
        if let text = value.dateTime {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
            guard let zone = (value.timeZone ?? fallbackZone).flatMap(TimeZone.init(identifier:)) else { throw GoogleCalendarError.invalidResponse }
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = zone; format.isLenient = false
            for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                format.dateFormat = pattern
                if let date = format.date(from: text), format.string(from: date) == text { return date }
            }
        } else if let text = value.date, let zone = (value.timeZone ?? fallbackZone).flatMap(TimeZone.init(identifier:)) {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
            format.timeZone = zone; format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
            if let date = format.date(from: text), format.string(from: date) == text { return date }
        }
        throw GoogleCalendarError.invalidResponse
    }
}
