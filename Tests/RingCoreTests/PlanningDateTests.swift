import Foundation
import RingCore

final class PlanningDateTests {
    private let settings = PlanningSettings()
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testNextWorkdayForEveryWeekdayAndMonthYearBoundaries() {
        let cases = [
            ("2026-11-02T17:00:00Z", "2026-11-03"),
            ("2026-11-03T17:00:00Z", "2026-11-04"),
            ("2026-11-04T17:00:00Z", "2026-11-05"),
            ("2026-11-05T17:00:00Z", "2026-11-06"),
            ("2026-11-06T17:00:00Z", "2026-11-09"),
            ("2026-11-07T17:00:00Z", "2026-11-09"),
            ("2026-11-08T17:00:00Z", "2026-11-09"),
            ("2026-10-30T16:00:00Z", "2026-11-02"),
            ("2027-12-31T17:00:00Z", "2028-01-03")
        ]
        for (stamp, expected) in cases {
            let next = PlannerDate.nextWorkingDay(after: date(stamp), settings: settings)
            XCTAssertEqual(PlannerDate.key(next, settings: settings), expected)
            XCTAssertEqual(next, PlannerDate.calendar(settings).startOfDay(for: next))
        }
    }

    func testNextWorkdayUsesPlanningTimeZoneAndCalendarDaysAcrossDST() {
        // UTC Monday is still Sunday in Toronto; UTC Friday is Thursday evening.
        XCTAssertEqual(PlannerDate.key(PlannerDate.nextWorkingDay(after: date("2026-11-09T02:30:00Z"), settings: settings), settings: settings), "2026-11-09")
        XCTAssertEqual(PlannerDate.key(PlannerDate.nextWorkingDay(after: date("2026-11-06T02:30:00Z"), settings: settings), settings: settings), "2026-11-06")
        for (friday, monday) in [
            ("2026-03-07T04:30:00Z", "2026-03-09T04:00:00Z"),
            ("2026-10-31T03:30:00Z", "2026-11-02T05:00:00Z")
        ] {
            XCTAssertEqual(PlannerDate.nextWorkingDay(after: date(friday), settings: settings), date(monday))
        }
        var tokyo = settings; tokyo.timeZone = "Asia/Tokyo"
        XCTAssertEqual(PlannerDate.key(PlannerDate.nextWorkingDay(after: date("2026-11-05T23:30:00Z"), settings: tokyo), settings: tokyo), "2026-11-09")
    }
}
