import XCTest

/// Drives the sample app with demo cards. The simulator has no NFC reader, so
/// the app falls back to demo cards and every result screen can be checked.
@MainActor
final class ICReadSampleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAValidCardShowsTheValidityPeriodAndIssuer() {
        let app = read(card: "valid")
        let validity = app.staticTexts["result-validity"]
        XCTAssertTrue(validity.waitForExistence(timeout: 10))
        XCTAssertEqual(validity.label, "状態、有効")  // VoiceOver reads the row title with the value
        XCTAssertTrue(app.staticTexts["result-period"].exists)
    }

    func testAnExpiredCardIsAResultNotAnError() {
        let app = read(card: "expired")
        let validity = app.staticTexts["result-validity"]
        XCTAssertTrue(validity.waitForExistence(timeout: 10))
        XCTAssertEqual(validity.label, "状態、期限切れ")
        XCTAssertFalse(app.staticTexts["error-message"].exists)
    }

    func testAnotherKindOfCardIsExplained() {
        let app = read(card: "other-card")
        let message = app.staticTexts["error-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("対応していません"))
    }

    func testACardThatMovesAwayAsksToHoldItStill() {
        let app = read(card: "connection-lost")
        let message = app.staticTexts["error-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("動かさずに"))
    }

    func read(card: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["demo-card-\(card)"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        app.buttons["read-button"].tap()
        return app
    }
}

extension ICReadSampleUITests {
    func testTheFunnelCountsAnAbandonedRead() {
        let app = read(card: "connection-lost")
        let rate = app.staticTexts["funnel-abandon-rate"]
        // The measurement section sits below the result; a List only builds rows it shows.
        XCTAssertTrue(app.staticTexts["error-message"].waitForExistence(timeout: 10))
        for _ in 0..<4 where !rate.exists { app.swipeUp() }
        XCTAssertTrue(rate.waitForExistence(timeout: 5))
        XCTAssertTrue(rate.label.contains("100"))
    }
}
