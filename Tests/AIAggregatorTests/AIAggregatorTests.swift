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
}
