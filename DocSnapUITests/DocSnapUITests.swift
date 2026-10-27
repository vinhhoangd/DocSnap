import XCTest

/// End-to-end flows on the simulator using the built-in sample document
/// (the simulator has no camera feed, so the VisionKit scanner can't capture here).
final class DocSnapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestingSampleData"]
        app.launch()
    }

    // MARK: - Helpers

    private var documentRow: XCUIElement { app.buttons["documentRow"].firstMatch }

    /// Waits for the seeded sample document and opens it.
    private func openSampleDocument() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20), "Sample document never appeared")
        documentRow.tap()
        XCTAssertTrue(app.buttons["pageCell"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Opens the page viewer on the first page and waits until its edit bar is usable.
    private func openFirstPage() {
        openSampleDocument()
        app.buttons["pageCell"].firstMatch.tap()
        waitUntilEnabled(app.buttons["rotateButton"])
    }

    /// The page viewer disables its edit bar while an edit renders; taps in that window are dropped.
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 15,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never became enabled", file: file, line: line)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)],
                                    timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) is still on screen", file: file, line: line)
    }

    private func element(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // MARK: - Existing flows

    func testSampleDocumentAppearsAndOpens() {
        openSampleDocument()
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 2)
    }

    func testEditPageRotateFilterAndText() {
        openFirstPage()
        app.buttons["rotateButton"].tap()

        // Rotation re-renders the page; Filters is disabled until that finishes.
        let filters = app.buttons["filtersButton"]
        waitUntilEnabled(filters)
        filters.tap()
        let bw = app.buttons["filter-blackWhite"]
        XCTAssertTrue(bw.waitForExistence(timeout: 5))
        bw.tap()

        let text = app.buttons["textButton"]
        waitUntilEnabled(text)
        text.tap()
        XCTAssertTrue(app.navigationBars["Page 1"].waitForExistence(timeout: 30))
    }

    func testCropScreenOpensAndCloses() {
        openFirstPage()
        app.buttons["cropButton"].tap()
        let done = app.buttons["cropDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["cropHandle0"].waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.buttons["rotateButton"].waitForExistence(timeout: 10))
    }

    func testScanButtonDoesNotCrashWithoutCamera() {
        let scan = app.buttons["scanButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20))
        scan.tap()
        // iOS 17/18 simulators report no document camera → DocSnap shows its own alert.
        // iOS 26 simulators report VNDocumentCameraViewController.isSupported == true and open the
        // VisionKit scanner with no camera feed; it then fails with AVFoundationErrorDomain -11800, which
        // DocSnap reports in its "Scan Failed" alert. Either way the user must be able to back out.
        let unavailable = app.alerts["Camera Unavailable"]
        let scannerHint = app.staticTexts["Position the document in view."]
        let appeared = unavailable.waitForExistence(timeout: 5) || scannerHint.waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "Neither the Camera Unavailable alert nor the VisionKit scanner appeared")
        if unavailable.exists {
            unavailable.buttons["Cancel"].tap()
        } else {
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
            let failed = app.alerts["Scan Failed"]
            if failed.waitForExistence(timeout: 5) {
                failed.buttons["OK"].tap()
            }
        }
        // The full-screen scanner animates away; wait for the library to be tappable again.
        let back = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: scan)],
                                  timeout: 10)
        XCTAssertEqual(back, .completed, "Library should be back in front after cancelling")
        XCTAssertTrue(documentRow.exists)
    }

    // MARK: - Document menu

    func testRenameDocumentFromMenu() {
        openSampleDocument()
        app.buttons["documentMenu"].tap()
        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let alert = app.alerts["Rename"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Sample Invoice", "Rename should start from the current title")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Hóa đơn tháng 10")
        alert.buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["Hóa đơn tháng 10"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Hóa đơn tháng 10"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sample Invoice"].exists)
    }

    func testReorderSheetOpensAndCloses() {
        openSampleDocument()
        app.buttons["documentMenu"].tap()
        let reorder = app.buttons["Reorder Pages"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 5))
        reorder.tap()

        XCTAssertTrue(app.navigationBars["Reorder Pages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Page 1"].exists)
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
        app.navigationBars["Reorder Pages"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Reorder Pages"])
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 2)
    }

    // MARK: - Page viewer

    func testDeletePageFromViewer() {
        openFirstPage()
        XCTAssertTrue(app.navigationBars["1 / 2"].exists)
        app.buttons["deletePageButton"].tap()
        let confirm = app.buttons["Delete Page"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.navigationBars["1 / 1"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["pageCell"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(labelContaining: "1 page").waitForExistence(timeout: 5))
    }

    func testDeletingLastPageReturnsToEmptyDocument() {
        openFirstPage()
        for _ in 0..<2 {
            let delete = app.buttons["deletePageButton"]
            waitUntilEnabled(delete)
            delete.tap()
            let confirm = app.buttons["Delete Page"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            waitForDisappearance(confirm)
        }
        // With no pages left the viewer closes itself and the document shows its empty state.
        XCTAssertTrue(app.staticTexts["No Pages"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["deletePageButton"].exists)
        XCTAssertFalse(app.buttons["shareButton"].isEnabled, "Share must be disabled for an empty document")
    }

    // MARK: - Library

    func testSettingsSheetShowsPageSize() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20))
        // No accessibility identifier on the Settings toolbar button; its label is "Settings".
        app.navigationBars["DocSnap"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Page Size").waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Default Filter").exists)
        XCTAssertTrue(app.switches.firstMatch.exists, "Searchable PDF toggle missing")
        app.navigationBars["Settings"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Settings"])
    }

    func testSearchFiltersTheList() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("invoice") // case-insensitive
        XCTAssertTrue(documentRow.waitForExistence(timeout: 5))

        search.typeText("zzz")
        waitForDisappearance(documentRow)
        XCTAssertTrue(element(labelContaining: "No Results").waitForExistence(timeout: 5))

        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        XCTAssertTrue(documentRow.waitForExistence(timeout: 5), "Clearing the query should bring the document back")
    }
}
