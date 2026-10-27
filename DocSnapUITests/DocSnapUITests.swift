import XCTest

/// End-to-end flows on the simulator using the built-in sample document
/// (the simulator has no camera, so the VisionKit scanner can't be driven here).
final class DocSnapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestingSampleData"]
        app.launch()
    }

    func testSampleDocumentAppearsAndOpens() {
        let row = app.buttons["documentRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.buttons["pageCell"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 2)
    }

    func testEditPageRotateFilterAndText() {
        let row = app.buttons["documentRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        app.buttons["pageCell"].firstMatch.tap()

        let rotate = app.buttons["rotateButton"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        rotate.tap()

        app.buttons["filtersButton"].tap()
        let bw = app.buttons["filter-blackWhite"]
        XCTAssertTrue(bw.waitForExistence(timeout: 5))
        bw.tap()

        app.buttons["textButton"].tap()
        XCTAssertTrue(app.navigationBars["Page 1"].waitForExistence(timeout: 30))
    }

    func testCropScreenOpensAndCloses() {
        let row = app.buttons["documentRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        app.buttons["pageCell"].firstMatch.tap()
        let crop = app.buttons["cropButton"]
        XCTAssertTrue(crop.waitForExistence(timeout: 10))
        crop.tap()
        let done = app.buttons["cropDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["cropHandle0"].waitForExistence(timeout: 10) || app.buttons["cropHandle0"].exists
                      || app.images["cropHandle0"].exists || app.descendants(matching: .any)["cropHandle0"].exists)
        done.tap()
        XCTAssertTrue(app.buttons["rotateButton"].waitForExistence(timeout: 10))
    }

    func testScanButtonOnSimulatorOffersPhotoImport() {
        let scan = app.buttons["scanButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20))
        scan.tap()
        // No camera in the simulator → friendly alert instead of a crash.
        XCTAssertTrue(app.alerts["Camera Unavailable"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
    }
}
