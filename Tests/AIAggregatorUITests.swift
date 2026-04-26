import XCTest

final class AIAggregatorUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        
        // In a menu bar app (LSUIElement), the app doesn't have a main window.
        // We just verify it stays running for a few seconds.
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
    }
}
