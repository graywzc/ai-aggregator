import Testing
import Foundation
@testable import AIAggregator

@Suite("UsageService")
@MainActor
struct AIAggregatorTests {

    @Test func windowLabel() {
        let svc = UsageService.shared
        #expect(svc.windowLabel(seconds: 86400) == "1d")
        #expect(svc.windowLabel(seconds: 3600)  == "1h")
        #expect(svc.windowLabel(seconds: 60)    == "1m")
        #expect(svc.windowLabel(seconds: 45)    == "45s")
    }

    @Test func parseDate() {
        let svc = UsageService.shared
        #expect(svc.parseDate("2026-04-25T20:00:00Z")             != nil)
        #expect(svc.parseDate("2026-04-26T02:30:00.770702+00:00") != nil)
        #expect(svc.parseDate(1714080000.0 as Double)             != nil)
    }

    @Test func extractReset() {
        let svc = UsageService.shared
        let dict1: [String: Any] = ["reset_at": "2026-04-25T20:00:00Z"]
        #expect(svc.extractReset(from: dict1) != nil)

        let dict2: [String: Any] = ["resets_in_seconds": 3600.0]
        let date = svc.extractReset(from: dict2)
        #expect(date != nil)
        if let date {
            #expect(date.timeIntervalSinceNow > 3500)
        }
    }

    // MARK: - formatResetDate

    @Test func formatResetDate_sameDay_returnsTimeOnly() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = 14
        comps.minute = 30
        let resetDate = Calendar.current.date(from: comps)!
        let result = formatResetDate(resetDate, relativeTo: Date())
        #expect(result == "14:30")
    }

    @Test func formatResetDate_differentDay_includesDayPrefix() {
        let future = Date().addingTimeInterval(2 * 86400)
        let result = formatResetDate(future, relativeTo: Date())
        #expect(result.count > 5)
        #expect(result.contains(":"))
    }

    @Test func formatResetDate_localeIsFixed() {
        let monday = ISO8601DateFormatter().date(from: "2026-05-04T10:00:00Z")!
        let sunday = ISO8601DateFormatter().date(from: "2026-05-03T10:00:00Z")!
        let result = formatResetDate(monday, relativeTo: sunday)
        #expect(result.hasPrefix("Mon"))
    }

    // MARK: - UsageWindow stats badge content

    @Test func usageWindowLowPercent_flaggedByThreshold() {
        let low = UsageWindow(label: "5h", percentRemaining: 15, resetsAt: nil)
        let ok  = UsageWindow(label: "7d", percentRemaining: 50, resetsAt: nil)
        #expect(low.percentRemaining < 20)
        #expect(!(ok.percentRemaining < 20))
    }

    @Test func usageWindowBadgeText_withReset() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = 9
        comps.minute = 0
        let resetDate = Calendar.current.date(from: comps)!
        let window = UsageWindow(label: "5h", percentRemaining: 80, resetsAt: resetDate)
        let badge = window.resetsAt.map { "5h: 80% · resets \(formatResetDate($0))" } ?? "5h: 80%"
        #expect(badge == "5h: 80% · resets 09:00")
    }

    @Test func usageWindowBadgeText_withoutReset() {
        let window = UsageWindow(label: "7d", percentRemaining: 42, resetsAt: nil)
        let badge = window.resetsAt.map { "7d: 42% · resets \(formatResetDate($0))" } ?? "7d: 42%"
        #expect(badge == "7d: 42%")
    }
}
