import Foundation
import RingCore

private actor CalendarStub: CalendarProviding {
    var permission: CalendarAccess = .full
    var grants = true
    var choices = [CalendarDescriptor(id: "google", title: "Work", account: "Google"), CalendarDescriptor(id: "other", title: "Personal", account: "Other")]
    var values: [CalendarOccurrence] = []
    var reads: [(DateInterval, Set<String>)] = []
    var calendarQueries = 0
    var hold = false
    var pending: [CheckedContinuation<Void, Never>] = []
    func access() -> CalendarAccess { permission }
    func requestAccess() -> Bool { permission = grants ? .full : .denied; return grants }
    func calendars(refresh: Bool) -> [CalendarDescriptor] { calendarQueries += 1; return choices }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) async -> [CalendarOccurrence] {
        reads.append((interval, calendarIDs)); let result = values
        if hold { await withCheckedContinuation { pending.append($0) } }
        return result
    }
    func configure(permission: CalendarAccess = .full, grants: Bool = true, values: [CalendarOccurrence] = [], hold: Bool = false) {
        self.permission = permission; self.grants = grants; self.values = values; self.hold = hold
    }
    func waiting() -> Bool { !pending.isEmpty }
    func waitingCount() -> Int { pending.count }
    func release() { let replies = pending; pending = []; for reply in replies { reply.resume() } }
}

struct CalendarTests {
    @MainActor func testRefreshAwaitsScheduleReconciliationAndRejectsLateDisconnect() async throws {
        let provider = CalendarStub(), defaults = preferences().0
        defaults.set(true, forKey: "googleCalendar.enabled"); defaults.set(["google"], forKey: "googleCalendar.selectedIDs")
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        var finished = false
        connection.onRefresh = { _ in
            try? await Task.sleep(for: .milliseconds(20))
            finished = true
        }
        XCTAssertTrue(await connection.refresh(day: day, settings: settings) != nil)
        XCTAssertTrue(finished)
        connection.onRefresh = { _ in await connection.disconnect() }
        XCTAssertTrue(await connection.refresh(day: day, settings: settings) == nil)
        XCTAssertFalse(connection.enabled)
    }
    private let settings = PlanningSettings()
    private var day: Date { ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")! }
    private func preferences() -> (UserDefaults, String) {
        let name = "one-ring-calendar-check-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func event(_ id: String, calendar: String = "google", from: Int = 600, to: Int = 660, busy: Bool = true, allDay: Bool = false) -> CalendarOccurrence {
        CalendarOccurrence(id: id, calendarID: calendar, title: "Synthetic meeting", calendarTitle: "Work", start: PlannerDate.at(from, on: day, settings: settings), end: PlannerDate.at(to, on: day, settings: settings), allDay: allDay, busy: busy)
    }
    func testOccurrencesAndBusyNormalization() {
        let window = DateInterval(start: PlannerDate.at(540, on: day, settings: settings), end: PlannerDate.at(1020, on: day, settings: settings))
        XCTAssertEqual(event("recurring").id, event("recurring").id)
        XCTAssertTrue(event("recurring").id != event("recurring", from: 700, to: 730).id)
        XCTAssertTrue(event("recurring").id != event("recurring", calendar: "other").id)
        XCTAssertEqual(event("early", from: 480, to: 600).meeting(in: window)?.start, window.start)
        XCTAssertEqual(event("late", from: 960, to: 1080).meeting(in: window)?.end, window.end)
        XCTAssertEqual(event("free", busy: false).meeting(in: window), nil)
        XCTAssertEqual(event("outside", from: 420, to: 480).meeting(in: window), nil)
        let allDay = event("day", from: 0, to: 1439, allDay: true).meeting(in: window)
        XCTAssertEqual(allDay?.start, window.start); XCTAssertEqual(allDay?.end, window.end)
        XCTAssertTrue(allDay?.context.contains("All day") == true)
    }
    @MainActor func testPermissionAndExplicitSelection() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let provider = CalendarStub()
        await provider.configure(permission: .notDetermined, grants: false)
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.connect(day: day, settings: settings)
        XCTAssertFalse(connection.connected); XCTAssertEqual(connection.access, .denied)
        XCTAssertTrue(connection.message?.contains("calendar read access") == true)
        XCTAssertEqual(await provider.calendarQueries, 0); XCTAssertEqual(await provider.reads.count, 0)
        await provider.configure()
        await connection.connect(day: day, settings: settings)
        XCTAssertEqual(connection.status, "Choose calendars"); XCTAssertFalse(connection.connected)
        XCTAssertEqual(await provider.reads.count, 0)
        connection.select("google", included: true)
        await connection.refresh(day: day, settings: settings)
        XCTAssertTrue(connection.connected); XCTAssertTrue(connection.events.isEmpty); XCTAssertTrue(connection.lastRead != nil)
        XCTAssertEqual(await provider.reads.last?.1, Set(["google"]))
    }
    @MainActor func testSelectedCalendarBoundsDSTAndRestart() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let provider = CalendarStub()
        let busy = event("busy"), free = event("free", from: 700, to: 730, busy: false)
        await provider.configure(values: [busy, busy, free, event("private", calendar: "other")])
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.connect(day: day, settings: settings)
        connection.select("google", included: true)
        await connection.refresh(day: day, settings: settings)
        XCTAssertEqual(connection.events.count, 2)
        XCTAssertTrue(connection.events.allSatisfy { $0.calendarID == "google" })
        XCTAssertEqual(connection.loadedInterval?.duration, 25 * 3600)
        let meetings = try connection.meetings(day: day, settings: settings)
        XCTAssertEqual(meetings.count, 1); XCTAssertTrue(meetings[0].pinned)
        let tomorrow = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        XCTAssertThrowsError(try connection.meetings(day: tomorrow, settings: settings))
        let restarted = CalendarConnection(provider: provider, defaults: defaults)
        XCTAssertTrue(restarted.enabled); XCTAssertEqual(restarted.selectedIDs, Set(["google"]))
        XCTAssertFalse(restarted.connected)
        await restarted.refresh(day: day, settings: settings)
        XCTAssertTrue(restarted.connected)
        await provider.configure(permission: .denied)
        await restarted.refresh(day: day, settings: settings)
        XCTAssertFalse(restarted.connected); XCTAssertTrue(restarted.events.isEmpty); XCTAssertEqual(restarted.lastRead, nil)
    }
    @MainActor func testDisconnectRejectsLateReadsAndMissingCalendar() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let provider = CalendarStub()
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.connect(day: day, settings: settings)
        connection.select("google", included: true)
        await provider.configure(values: [event("late")], hold: true)
        let refresh = Task { await connection.refresh(day: day, settings: settings) }
        while !(await provider.waiting()) { await Task.yield() }
        await connection.disconnect()
        await provider.release(); _ = await refresh.value
        XCTAssertFalse(connection.enabled); XCTAssertFalse(connection.connected)
        XCTAssertTrue(connection.events.isEmpty); XCTAssertEqual(connection.lastRead, nil)
        defaults.set(true, forKey: "googleCalendar.enabled"); defaults.set(["removed"], forKey: "googleCalendar.selectedIDs")
        await provider.configure()
        let missing = CalendarConnection(provider: provider, defaults: defaults)
        await missing.refresh(day: day, settings: settings)
        XCTAssertFalse(missing.connected); XCTAssertTrue(missing.hasMissingCalendars)
        XCTAssertThrowsError(try missing.meetings(day: day, settings: settings))
        missing.clearMissingCalendars(); missing.select("google", included: true)
        await missing.refresh(day: day, settings: settings)
        XCTAssertTrue(missing.connected)
    }
    @MainActor func testSchedulerAvoidsSelectedBusyEvents() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let provider = CalendarStub()
        await provider.configure(values: [event("busy")])
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.connect(day: day, settings: settings); connection.select("google", included: true)
        await connection.refresh(day: day, settings: settings)
        let meetings = try connection.meetings(day: day, settings: settings)
        let task = PlannerTask(title: "Synthetic work", state: .ready, importance: true, urgency: false, remainingMinutes: 180)
        let plan = Scheduler().makePlan(day: day, now: PlannerDate.at(500, on: day, settings: settings), tasks: [task], routines: [], settings: settings, meetings: meetings)
        XCTAssertEqual(plan.blocks.filter { $0.kind == .meeting }.map(\.id), meetings.map(\.id))
        for focus in plan.blocks.filter({ $0.kind == .focus }) {
            XCTAssertTrue(meetings.allSatisfy { focus.end <= $0.start || focus.start >= $0.end })
        }
        XCTAssertEqual(plan.unscheduled.count, 0)
    }
    @MainActor func testConcurrentReadsKeepTheirDatesAndLatestUI() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let provider = CalendarStub()
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.connect(day: day, settings: settings); connection.select("google", included: true)
        await provider.configure(values: [event("day-one")], hold: true)
        let first = Task { await connection.refresh(day: day, settings: settings) }
        while await provider.waitingCount() < 1 { await Task.yield() }
        let tomorrow = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: day)!
        let second = Task { await connection.refresh(day: tomorrow, settings: settings) }
        while await provider.waitingCount() < 2 { await Task.yield() }
        await provider.release()
        let firstRead = await first.value, secondRead = await second.value
        XCTAssertEqual(try firstRead?.meetings(day: day, settings: settings).count, 1)
        XCTAssertEqual(try secondRead?.meetings(day: tomorrow, settings: settings).count, 0)
        XCTAssertEqual(connection.loadedInterval?.start, PlannerDate.calendar(settings).startOfDay(for: tomorrow))
        XCTAssertTrue(connection.events.isEmpty); XCTAssertTrue(connection.connected)
        XCTAssertThrowsError(try connection.meetings(day: day, settings: settings))
    }
}

extension CalendarTests {
    @MainActor func testRangeReadsPreserveDailyPlanningSnapshot() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "googleCalendar.enabled"); defaults.set(["google"], forKey: "googleCalendar.selectedIDs")
        let provider = CalendarStub(); await provider.configure(values: [event("selected"), event("foreign", calendar: "other")])
        let connection = CalendarConnection(provider: provider, defaults: defaults)
        var refreshes = 0; connection.onRefresh = { _ in refreshes += 1 }
        await connection.refresh(day: day, settings: settings)
        let dailyEvents = connection.events, dailyInterval = connection.loadedInterval, dailyRead = connection.lastRead
        let days = CalendarGrid.days(containing: day, week: true, calendar: PlannerDate.calendar(settings))
        let interval = DateInterval(start: days[0], end: PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: days.last!)!)
        let read = try await connection.readRange(interval)
        XCTAssertEqual(read.events, dailyEvents); XCTAssertEqual(read.calendarIDs, Set(["google"]))
        XCTAssertEqual(connection.events, dailyEvents); XCTAssertEqual(connection.loadedInterval, dailyInterval); XCTAssertEqual(connection.lastRead, dailyRead)
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(try !connection.meetings(day: day, settings: settings).isEmpty)
        XCTAssertEqual(await provider.reads.last?.0, interval)
    }
    @MainActor func testRangeReadsRejectLateSelectionAndCancellation() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "googleCalendar.enabled"); defaults.set(["google"], forKey: "googleCalendar.selectedIDs")
        let provider = CalendarStub(), connection = CalendarConnection(provider: provider, defaults: defaults)
        await connection.refresh(day: day, settings: settings)
        let interval = connection.loadedInterval!
        await provider.configure(values: [event("late")], hold: true)
        let read = Task { try await connection.readRange(interval) }
        while !(await provider.waiting()) { await Task.yield() }
        connection.select("other", included: true)
        await provider.release()
        do { _ = try await read.value; XCTAssertTrue(false) } catch CalendarConnectionError.changedDuringRead {} catch { XCTAssertTrue(false) }
        XCTAssertTrue(connection.events.isEmpty)
        let cancelled = Task { try await connection.readRange(interval) }
        while !(await provider.waiting()) { await Task.yield() }
        cancelled.cancel(); await provider.release()
        do { _ = try await cancelled.value; XCTAssertTrue(false) } catch is CancellationError {} catch { XCTAssertTrue(false) }
        await provider.configure(permission: .denied)
        do { _ = try await connection.readRange(interval); XCTAssertTrue(false) } catch CalendarConnectionError.accessRequired {} catch { XCTAssertTrue(false) }
    }
}
