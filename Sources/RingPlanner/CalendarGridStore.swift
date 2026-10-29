import SwiftUI
import RingCore

@MainActor final class CalendarGridStore: ObservableObject {
    @Published private(set) var events: [CalendarOccurrence] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var lastRead: Date?
    @Published private(set) var loadedInterval: DateInterval?
    @Published private(set) var loadedIDs = Set<String>()
    private var generation = UUID()
    func load(_ interval: DateInterval, connection: CalendarConnection, demo: Bool, examples: [CalendarOccurrence]) async {
        let id = UUID(); generation = id; events = []; message = nil; lastRead = nil; loadedInterval = nil; loadedIDs = []
        guard !demo else { events = examples.filter { $0.start < interval.end && $0.end > interval.start }; loadedInterval = interval; lastRead = Date(); return }
        guard connection.enabled else { loading = false; return }
        loading = true
        defer { if generation == id { loading = false } }
        do {
            let read = try await connection.readRange(interval)
            try Task.checkCancellation()
            guard generation == id else { return }
            events = read.events; loadedInterval = read.interval; loadedIDs = read.calendarIDs; lastRead = Date()
        } catch is CancellationError { }
        catch {
            guard generation == id else { return }
            message = "Couldn’t load Google events for this range. Saved local plans are shown. \(error.localizedDescription)"
        }
    }
}
