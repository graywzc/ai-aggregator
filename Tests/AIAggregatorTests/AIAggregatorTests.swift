import XCTest
@testable import AIAggregator

final class AIAggregatorTests: XCTestCase {
    var usageService: UsageService!

    override func setUp() {
        super.setUp()
        usageService = UsageService.shared
    }

    func testWindowLabel() {
        XCTAssertEqual(usageService.windowLabel(seconds: 86400), "1d")
        XCTAssertEqual(usageService.windowLabel(seconds: 3600), "1h")
        XCTAssertEqual(usageService.windowLabel(seconds: 60), "1m")
        XCTAssertEqual(usageService.windowLabel(seconds: 45), "45s")
    }

    func testParseDate() {
        // Test standard ISO8601
        let dateStr = "2026-04-25T20:00:00Z"
        XCTAssertNotNil(usageService.parseDate(dateStr))
        
        // Test fractional seconds (ChatGPT/Claude style)
        let fractionalStr = "2026-04-26T02:30:00.770702+00:00"
        XCTAssertNotNil(usageService.parseDate(fractionalStr))
        
        // Test epoch
        let epoch: Double = 1714080000
        XCTAssertNotNil(usageService.parseDate(epoch))
    }

    func testExtractReset() {
        let dict: [String: Any] = ["reset_at": "2026-04-25T20:00:00Z"]
        XCTAssertNotNil(usageService.extractReset(from: dict))

        let dictSeconds: [String: Any] = ["resets_in_seconds": 3600.0]
        let date = usageService.extractReset(from: dictSeconds)
        XCTAssertNotNil(date)
        // Should be roughly 1 hour from now
        if let date = date {
            XCTAssertTrue(date.timeIntervalSinceNow > 3500)
        }
    }

    // MARK: - formatResetDate

    func testFormatResetDate_sameDay_returnsTimeOnly() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 14
        comps.minute = 30
        let resetDate = Calendar.current.date(from: comps)!
        let result = formatResetDate(resetDate, relativeTo: Date())
        XCTAssertEqual(result, "14:30")
    }

    func testFormatResetDate_differentDay_includesDayPrefix() {
        // Use a date 2 days from now so it's definitely a different day.
        let future = Date().addingTimeInterval(2 * 86400)
        let result = formatResetDate(future, relativeTo: Date())
        // Should contain a day abbreviation (3 letters) followed by a space and time.
        XCTAssertTrue(result.count > 5, "Expected 'EEE HH:mm' format but got: \(result)")
        XCTAssertTrue(result.contains(":"), "Expected time part with ':' but got: \(result)")
    }

    func testFormatResetDate_localeIsFixed() {
        // Verify day names are always English regardless of system locale.
        let monday = ISO8601DateFormatter().date(from: "2026-05-04T10:00:00Z")! // a Monday
        let sunday = ISO8601DateFormatter().date(from: "2026-05-03T10:00:00Z")! // previous day (Sunday)
        let result = formatResetDate(monday, relativeTo: sunday)
        XCTAssertTrue(result.hasPrefix("Mon"), "Expected English day name but got: \(result)")
    }

    // MARK: - UsageWindow stats badge content

    func testUsageWindowLowPercent_flaggedByThreshold() {
        let low = UsageWindow(label: "5h", percentRemaining: 15, resetsAt: nil)
        let ok  = UsageWindow(label: "7d", percentRemaining: 50, resetsAt: nil)
        XCTAssertTrue(low.percentRemaining < 20)
        XCTAssertFalse(ok.percentRemaining < 20)
    }

    func testUsageWindowBadgeText_withReset() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9
        comps.minute = 0
        let resetDate = Calendar.current.date(from: comps)!
        let window = UsageWindow(label: "5h", percentRemaining: 80, resetsAt: resetDate)
        let badge = window.resetsAt.map { "5h: 80% · resets \(formatResetDate($0))" } ?? "5h: 80%"
        XCTAssertEqual(badge, "5h: 80% · resets 09:00")
    }

    func testUsageWindowBadgeText_withoutReset() {
        let window = UsageWindow(label: "7d", percentRemaining: 42, resetsAt: nil)
        let badge = window.resetsAt.map { "7d: 42% · resets \(formatResetDate($0))" } ?? "7d: 42%"
        XCTAssertEqual(badge, "7d: 42%")
    }
}
