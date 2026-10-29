import Foundation

extension GoogleCalendarProvider {
    /// Read by stable ID so moves beyond the original day are still found. This never writes to Google.
    public func eventTimes(_ publication: CalendarPublication, missingAllowed: Bool = false, skippingRemoved: Bool = false) async throws -> [CalendarEventTime] {
        let generation = try await validatePublication(publication, publishing: false)
        var times: [CalendarEventTime] = []
        for event in publication.desired {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            let (status, data) = try await eventRequest("GET", publication: publication, eventID: event.id, publishing: false)
            if status == 404 && missingAllowed { continue }
            if skippingRemoved && (status == 404 || status == 410) { continue }
            if status == 404 || status == 410 { throw CalendarPublicationError.removedEvent }
            try require(status, allowed: [200])
            if let tombstone = try? JSONDecoder().decode(PublishedRemoteEvent.self, from: data), tombstone.id == event.id,
               tombstone.kind == "calendar#event", tombstone.status == "cancelled" {
                if skippingRemoved { continue }; throw CalendarPublicationError.removedEvent
            }
            let remote = try remoteEvent(data, expected: event, publication: publication)
            if remote.status == "cancelled" { if skippingRemoved { continue }; throw CalendarPublicationError.removedEvent }
            guard let start = remote.start?.parsedDate, let end = remote.end?.parsedDate, start < end else { throw GoogleCalendarError.invalidResponse }
            times.append(CalendarEventTime(id: event.id, start: start, end: end))
        }
        return times
    }
    public func synchronize(_ publication: CalendarPublication, expectedTimes: [CalendarEventTime]? = nil) async throws {
        let generation = try await validatePublication(publication)
        for event in publication.desired {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            try await upsert(event, publication: publication, expectedTime: expectedTimes?.first { $0.id == event.id })
        }
        let desired = Set(publication.desired.map(\.id))
        for old in publication.known where !desired.contains(old.id) {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            let (status, data) = try await eventRequest("GET", publication: publication, eventID: old.id)
            if status == 404 || status == 410 { continue }
            try require(status, allowed: [200])
            let remote = try remoteEvent(data, expected: old, publication: publication)
            guard let etag = remote.etag else { throw GoogleCalendarError.invalidResponse }
            let (deleted, _) = try await eventRequest("DELETE", publication: publication, eventID: old.id, etag: etag)
            try require(deleted, allowed: [204, 404, 410])
        }
    }
    /// Exactly one occurrence, guarded against concurrent Google edits. No other fields or events are changed.
    public func applyBlockEdit(_ edit: CalendarBlockEdit) async throws {
        let p = edit.publication, event = edit.event
        guard p.desired.count == 1, p.known.allSatisfy({ $0.id == event.id }),
              CalendarBlockEditing.valid(start: event.start, end: event.end) else { throw CalendarPublicationError.invalidPlan }
        let generation = try await validatePublication(p)
        let (status, data) = try await eventRequest("GET", publication: p, eventID: event.id)
        guard generation == version else { throw GoogleCalendarError.cancelled }
        if status == 404 && edit.creating {
            let (inserted, response) = try await eventRequest("POST", publication: p, body: try eventBody(event, publication: p))
            if inserted == 409 {
                let (found, value) = try await eventRequest("GET", publication: p, eventID: event.id)
                try require(found, allowed: [200])
                let remote = try remoteEvent(value, expected: event, publication: p)
                guard remote.status != "cancelled", remote.start?.parsedDate == event.start, remote.end?.parsedDate == event.end else { throw CalendarPublicationError.conflict }
            } else {
                try require(inserted, allowed: [200, 201])
                guard try remoteEvent(response, expected: event, publication: p).matches(event) else { throw GoogleCalendarError.invalidResponse }
            }
            return
        }
        if status == 404 || status == 410 { throw CalendarPublicationError.removedEvent }
        try require(status, allowed: [200])
        let remote = try remoteEvent(data, expected: event, publication: p)
        guard remote.status != "cancelled" else { throw CalendarPublicationError.removedEvent }
        if remote.start?.parsedDate == event.start && remote.end?.parsedDate == event.end { return }
        guard remote.start?.parsedDate == edit.baselineStart && remote.end?.parsedDate == edit.baselineEnd else { throw CalendarPublicationError.conflict }
        guard let etag = remote.etag else { throw GoogleCalendarError.invalidResponse }
        let f = ISO8601DateFormatter()
        let body = try JSONSerialization.data(withJSONObject: [
            "start": ["dateTime": f.string(from: event.start), "timeZone": event.timeZone],
            "end": ["dateTime": f.string(from: event.end), "timeZone": event.timeZone]
        ])
        let (patched, response) = try await eventRequest("PATCH", publication: p, eventID: event.id, body: body, etag: etag)
        try require(patched, allowed: [200])
        let result = try remoteEvent(response, expected: event, publication: p)
        guard result.start?.parsedDate == event.start && result.end?.parsedDate == event.end else { throw GoogleCalendarError.invalidResponse }
    }
    /// Recolor existing owned events without creating, rescheduling or removing anything.
    @discardableResult public func applyEventColors(_ publication: CalendarPublication) async throws -> Int {
        let generation = try await validatePublication(publication)
        var seen = Set<String>(), changed = 0
        for event in publication.desired + publication.known where seen.insert(event.id).inserted {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            let (status, data) = try await eventRequest("GET", publication: publication, eventID: event.id)
            if status == 404 || status == 410 { continue }
            try require(status, allowed: [200])
            let remote = try remoteEvent(data, expected: event, publication: publication)
            if remote.status == "cancelled" || remote.colorId == event.googleColorID { continue }
            guard let etag = remote.etag else { throw GoogleCalendarError.invalidResponse }
            let (patched, response) = try await eventRequest("PATCH", publication: publication, eventID: event.id,
                body: try eventColorBody(event), etag: etag)
            try require(patched, allowed: [200])
            guard try remoteEvent(response, expected: event, publication: publication).colorId == event.googleColorID else { throw GoogleCalendarError.invalidResponse }
            changed += 1
        }
        return changed
    }
    private func validatePublication(_ publication: CalendarPublication, publishing: Bool = true) async throws -> UUID {
        if publishing { guard await oauth.publishingAuthorized() else { throw GoogleCalendarError.publishingPermission } }
        else { guard await oauth.authorized() else { throw GoogleCalendarError.signedOut } }
        let generation = version
        let destinations = try await publicationDestinations(refresh: true)
        guard generation == version else { throw GoogleCalendarError.cancelled }
        guard calendarAccountID() == publication.destination.accountID else { throw CalendarPublicationError.account }
        guard destinations.contains(where: { $0.id == publication.destination.id }) else { throw CalendarPublicationError.destination }
        let valid = publication.desired + publication.known
        guard Set(publication.desired.map(\.id)).count == publication.desired.count,
              valid.allSatisfy({ $0.hasValidSource && $0.start < $0.end && TimeZone(identifier: $0.timeZone) != nil &&
                  $0.id == CalendarPlanEvent.identifier(workspaceID: publication.workspaceID, day: publication.day, blockID: $0.blockID) }) else { throw CalendarPublicationError.invalidPlan }
        return generation
    }
    private func upsert(_ event: CalendarPlanEvent, publication: CalendarPublication, expectedTime: CalendarEventTime?) async throws {
        let (status, data) = try await eventRequest("GET", publication: publication, eventID: event.id)
        if status == 410 { throw CalendarPublicationError.removedEvent }
        if status == 404 {
            let (inserted, response) = try await eventRequest("POST", publication: publication, body: try eventBody(event, publication: publication))
            if inserted == 409 {
                // The earlier POST may have succeeded before its response was lost.
                let (found, value) = try await eventRequest("GET", publication: publication, eventID: event.id)
                try require(found, allowed: [200])
                _ = try remoteEvent(value, expected: event, publication: publication)
                try await updateIfNeeded(value, event: event, publication: publication)
            } else {
                try require(inserted, allowed: [200, 201])
                guard try remoteEvent(response, expected: event, publication: publication).matches(event) else { throw GoogleCalendarError.invalidResponse }
            }
        } else {
            try require(status, allowed: [200])
            if let expectedTime {
                let remote = try remoteEvent(data, expected: event, publication: publication)
                guard remote.start?.parsedDate == expectedTime.start && remote.end?.parsedDate == expectedTime.end else { throw CalendarPublicationError.conflict }
            }
            try await updateIfNeeded(data, event: event, publication: publication)
        }
    }
    private func updateIfNeeded(_ data: Data, event: CalendarPlanEvent, publication: CalendarPublication) async throws {
        let remote = try remoteEvent(data, expected: event, publication: publication)
        if remote.status == "cancelled" { throw CalendarPublicationError.removedEvent }
        if remote.matches(event) { return }
        guard let etag = remote.etag else { throw GoogleCalendarError.invalidResponse }
        // Patch only the planner's fields; unrelated metadata is left intact.
        let body = try remote.matchesPlan(event) ? eventColorBody(event) : eventBody(event, publication: publication, inserting: false)
        let (status, response) = try await eventRequest("PATCH", publication: publication, eventID: event.id, body: body, etag: etag)
        try require(status, allowed: [200])
        guard try remoteEvent(response, expected: event, publication: publication).matches(event) else { throw GoogleCalendarError.invalidResponse }
    }
    private func remoteEvent(_ data: Data, expected: CalendarPlanEvent, publication: CalendarPublication) throws -> PublishedRemoteEvent {
        guard let remote = try? JSONDecoder().decode(PublishedRemoteEvent.self, from: data), remote.id == expected.id,
              remote.kind == "calendar#event" else { throw GoogleCalendarError.invalidResponse }
        let properties = remote.extendedProperties?["private"] ?? [:]
        guard CalendarPlanEvent.isOwned(eventID: remote.id, metadata: properties, workspaceID: publication.workspaceID),
              properties["ringDay"] == publication.day, properties["ringBlock"] == expected.blockID,
              properties["ringTask"] == expected.taskID, properties["ringRoutine"] == expected.routineID, remote.attendees?.isEmpty != false,
              remote.recurrence?.isEmpty != false else { throw CalendarPublicationError.foreignEvent }
        return remote
    }
    private func eventBody(_ event: CalendarPlanEvent, publication: CalendarPublication, inserting: Bool = true) throws -> Data {
        let f = ISO8601DateFormatter()
        var body: [String: Any] = [
            "summary": event.title, "description": (event.kind == .routine ? "Routine planned with The One Ring Planner." : "Planned with The One Ring Planner.") + (event.context.isEmpty ? "" : "\nProject: \(event.context)"),
            "start": ["dateTime": f.string(from: event.start), "timeZone": event.timeZone],
            "end": ["dateTime": f.string(from: event.end), "timeZone": event.timeZone],
            "status": "confirmed", "transparency": "opaque", "visibility": "private", "colorId": event.googleColorID,
            "reminders": ["useDefault": false], "extendedProperties": ["private": event.metadata(workspaceID: publication.workspaceID, day: publication.day)]
        ]
        if inserting { body["id"] = event.id; body["eventType"] = "default" }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    private func eventColorBody(_ event: CalendarPlanEvent) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["colorId": event.googleColorID], options: [.sortedKeys])
    }
    private func eventRequest(_ method: String, publication: CalendarPublication, eventID: String? = nil, body: Data? = nil, etag: String? = nil, publishing: Bool = true) async throws -> (Int, Data) {
        let generation = version
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let calendar = publication.destination.id.addingPercentEncoding(withAllowedCharacters: allowed)!
        var url = URLComponents(string: "https://www.googleapis.com")!
        url.percentEncodedPath = "/calendar/v3/calendars/\(calendar)/events" + (eventID.map { "/\($0)" } ?? "")
        if method != "GET" { url.queryItems = [URLQueryItem(name: "sendUpdates", value: "none")] }
        var token = try await oauth.accessToken(publishing: publishing)
        for attempt in 0...1 {
            guard generation == version else { throw GoogleCalendarError.cancelled }
            var request = URLRequest(url: url.url!); request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard generation == version else { throw GoogleCalendarError.cancelled }
            guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            if response.statusCode == 401 {
                if attempt == 0 { token = try await oauth.accessToken(rejected: token, publishing: publishing); continue }
                try await oauth.disconnect(); throw GoogleCalendarError.signedOut
            }
            return (response.statusCode, data)
        }
        throw GoogleCalendarError.signedOut
    }
    private func require(_ status: Int, allowed: Set<Int>) throws {
        if status == 412 { throw CalendarPublicationError.conflict }
        guard allowed.contains(status) else { throw GoogleCalendarError.api(status) }
    }
}

private struct PublishedRemoteEvent: Decodable {
    struct Time: Decodable {
        let dateTime: String?; let timeZone: String?
        var parsedDate: Date? {
            guard let dateTime else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateTime) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateTime)
        }
    }
    struct Attendee: Decodable { let email: String? }
    let id: String
    let kind: String
    let etag: String?
    let status: String?
    let summary: String?
    let colorId: String?
    let start: Time?
    let end: Time?
    let extendedProperties: [String: [String: String]]?
    let attendees: [Attendee]?
    let recurrence: [String]?
    func matches(_ event: CalendarPlanEvent) -> Bool {
        matchesPlan(event) && colorId == event.googleColorID
    }
    func matchesPlan(_ event: CalendarPlanEvent) -> Bool {
        let f = ISO8601DateFormatter()
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            if let result = f.date(from: value) { return result }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: value)
        }
        return summary == event.title && date(start?.dateTime) == event.start && date(end?.dateTime) == event.end
    }
}
