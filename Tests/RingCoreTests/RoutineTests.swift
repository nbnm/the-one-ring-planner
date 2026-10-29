import Foundation
import RingCore

final class RoutineTests {
    var settings = PlanningSettings()
    let monday = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
    func routine(_ id: String = "reading", days: [RoutineWeekday] = RoutineWeekday.allCases, protected: Bool = false) -> Routine {
        Routine(id: id, title: "Read a chapter", minutes: 15, startMinute: 540, endMinute: 690, protected: protected, enabled: true, weekdays: days)
    }
    func plan(_ day: Date, _ routines: [Routine], previous: DayPlan? = nil) -> DayPlan {
        Scheduler().makePlan(day: day, now: PlannerDate.at(480, on: day, settings: settings), tasks: [], routines: routines, settings: settings, previous: previous)
    }
    func testDailyWeekdayWeekendAndCustomSchedules() {
        let routines = [routine("daily"), routine("weekday", days: RoutineWeekday.workdays), routine("weekend", days: RoutineWeekday.weekend, protected: true), routine("custom", days: [.monday, .wednesday], protected: true)]
        for offset in 0..<7 {
            let day = PlannerDate.calendar(settings).date(byAdding: .day, value: offset, to: monday)!
            let p = plan(day, routines)
            let ids = p.blocks.compactMap(\.routineID)
            XCTAssertEqual(ids.filter { $0 == "daily" }.count, 1)
            XCTAssertEqual(ids.contains("weekday"), offset < 5)
            XCTAssertEqual(ids.contains("weekend"), offset >= 5)
            XCTAssertEqual(ids.contains("custom"), offset == 0 || offset == 2)
            XCTAssertTrue(p.unscheduled.isEmpty)
        }
    }
    func testRepeatDaysUsePlanningTimeZoneAcrossDSTAndMidnight() {
        let sunday = routine(days: [.sunday])
        for stamp in ["2026-03-09T00:30:00Z", "2026-11-02T02:30:00Z"] {
            let localSunday = ISO8601DateFormatter().date(from: stamp)!
            XCTAssertTrue(sunday.occurs(on: localSunday, settings: settings))
            XCTAssertFalse(routine(days: [.monday]).occurs(on: localSunday, settings: settings))
            XCTAssertEqual(plan(localSunday, [sunday]).blocks.first { $0.routineID == sunday.id }.map { PlannerDate.calendar(settings).component(.hour, from: $0.start) }, 9)
            let end = PlannerDate.at(1440, on: localSunday, settings: settings)
            XCTAssertEqual(PlannerDate.key(end, settings: settings), PlannerDate.key(PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: localSunday)!, settings: settings))
            XCTAssertEqual(PlannerDate.calendar(settings).component(.hour, from: end), 0)
        }
        var tokyo = settings; tokyo.timeZone = "Asia/Tokyo"
        let utcSunday = ISO8601DateFormatter().date(from: "2026-10-25T23:30:00Z")!
        XCTAssertTrue(routine(days: [.monday]).occurs(on: utcSunday, settings: tokyo))
        XCTAssertFalse(sunday.occurs(on: utcSunday, settings: tokyo))
    }
    func testTurningOffDaysRemovesOnlyUnstartedOccurrences() {
        var r = routine(protected: true)
        var old = plan(monday, [r])
        let index = old.blocks.firstIndex { $0.routineID == r.id }!
        old.blocks[index].pinned = true
        let occurrence = old.blocks[index]
        XCTAssertTrue(plan(monday, [r], previous: old).blocks.contains(occurrence))
        r.weekdays = [.tuesday]
        XCTAssertFalse(plan(monday, [r], previous: old).blocks.contains { $0.routineID == r.id })
        for state in [BlockState.completed, .running, .interrupted, .skipped] {
            var history = old; history.blocks[index].state = state
            let rebuilt = plan(monday, [r], previous: history)
            XCTAssertEqual(rebuilt.blocks.filter { $0.routineID == r.id }, [history.blocks[index]])
        }
        r = routine(protected: true); r.enabled = false
        XCTAssertFalse(plan(monday, [r], previous: old).blocks.contains { $0.routineID == r.id })
    }
    func testOccurrencesCompleteIndependentlyWithoutReplanDuplicates() {
        let r = routine()
        var first = plan(monday, [r])
        let index = first.blocks.firstIndex { $0.routineID == r.id }!
        first.blocks[index].state = .completed
        let rebuilt = plan(monday, [r], previous: first)
        XCTAssertEqual(rebuilt.blocks.filter { $0.routineID == r.id }, [first.blocks[index]])
        let tomorrow = PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: monday)!
        let next = plan(tomorrow, [r])
        let occurrence = next.blocks.first { $0.routineID == r.id }!
        XCTAssertEqual(occurrence.state, .planned)
        XCTAssertFalse(occurrence.id == first.blocks[index].id)
    }
    func testCustomRoutinesAndLegacyTemplatesSurviveRestart() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        var custom = routine("custom", days: [.friday, .monday, .friday]); custom.title = "Read fiction"
        let another = Routine(title: "Read fiction", minutes: 20, startMinute: 600, endMinute: 660, enabled: true, weekdays: [.sunday])
        try repo.save(routines: Routine.defaults + [custom, another], message: "Create custom routines")
        let reopened = try DataRepository(root: repo.root, localState: repo.localState)
        let loaded = try reopened.load(Routine.self, directory: "routines")
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded.first { $0.id == custom.id }, custom)
        XCTAssertEqual(loaded.first { $0.id == another.id }, another)
        XCTAssertEqual(custom.weekdays, [.monday, .friday])
        let encoder = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(Routine.defaults[0])) as! [String: Any]
        legacy.removeValue(forKey: "weekdays"); legacy["schemaVersion"] = 1
        let decoded = try JSONDecoder().decode(Routine.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.weekdays, RoutineWeekday.allCases)
        XCTAssertEqual(decoded.enabled, false)
        XCTAssertEqual(decoded.id, Routine.defaults[0].id)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }
    func testInvalidRoutinesDoNotEnterDrafts() {
        var invalid: [Routine] = []
        var r = routine(); r.title = " \n"; invalid.append(r)
        r = routine(); r.weekdays = []; invalid.append(r)
        r = routine(); r.minutes = 0; invalid.append(r)
        r = routine(); r.endMinute = r.startMinute - 15; invalid.append(r)
        r = routine(); r.endMinute = r.startMinute + 5; invalid.append(r)
        r = routine(); r.startMinute = -15; invalid.append(r)
        r = routine(); r.endMinute = 1455; invalid.append(r)
        for candidate in invalid {
            XCTAssertTrue(candidate.validationMessage != nil)
            XCTAssertFalse(plan(monday, [candidate]).blocks.contains { $0.routineID == candidate.id })
        }
        XCTAssertEqual(routine().validationMessage, nil)
        XCTAssertEqual(routine(days: [.monday, .wednesday]).scheduleSummary, "Mon, Wed")
    }
}
