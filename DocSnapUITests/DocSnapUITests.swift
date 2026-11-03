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
        let rename = app.buttons["renameMenuItem"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let alert = app.alerts["Rename Document"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch // alert text fields don't expose SwiftUI identifiers
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
        let reorder = app.buttons["reorderMenuItem"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 5))
        reorder.tap()

        XCTAssertTrue(app.navigationBars["Reorder Pages"].waitForExistence(timeout: 5))
        // Each row is one accessibility element (thumbnail hidden as decorative), labelled "Page N".
        let rows = app.descendants(matching: .any).matching(identifier: "reorderRow")
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Page 1'")).firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Page 2'")).firstMatch.exists)
        app.navigationBars["Reorder Pages"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Reorder Pages"])
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 2)
    }

    // MARK: - Page viewer

    func testDeletePageFromViewer() {
        openFirstPage()
        XCTAssertTrue(app.navigationBars["1 / 2"].exists)
        app.buttons["deletePageButton"].tap()
        let confirm = app.buttons["confirmDeletePageButton"].firstMatch
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
            let confirm = app.buttons["confirmDeletePageButton"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            waitForDisappearance(confirm)
        }
        // With no pages left the viewer closes itself and the document shows its empty state.
        XCTAssertTrue(app.descendants(matching: .any)["noPagesView"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["deletePageButton"].exists)
        XCTAssertFalse(app.buttons["shareButton"].isEnabled, "Share must be disabled for an empty document")
    }

    // MARK: - Library

    func testSettingsSheetShowsPageSize() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Default Filter").waitForExistence(timeout: 5))
        // The Display, Camera and AI Answers sections push the PDF rows below the fold; the Form is lazy,
        // so off-screen rows aren't in the accessibility tree until scrolled to.
        let pageSize = element(labelContaining: "Page Size")
        for _ in 0..<6 where !pageSize.waitForExistence(timeout: 1) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(pageSize.waitForExistence(timeout: 5))
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

    func testAdjustBordersToggleSwitches() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["reviewBordersToggle"].firstMatch
        for _ in 0..<4 where !toggle.waitForExistence(timeout: 1) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Adjust Borders toggle missing:\n\(app.debugDescription)")
        let original = toggle.value as? String
        XCTAssertTrue(["0", "1"].contains(original ?? ""), "Unexpected toggle value \(String(describing: original))")

        // Tap the switch itself: tapping the middle of a Form row doesn't flip it.
        flip(toggle)
        XCTAssertNotEqual(toggle.value as? String, original, "Tapping should flip Adjust Borders")
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, original, "Second tap should restore the setting")

        app.navigationBars["Settings"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Settings"])
    }

    private func flip(_ toggle: XCUIElement) {
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = expectation(for: NSPredicate(format: "value != %@", before ?? ""), evaluatedWith: toggle)
        _ = XCTWaiter.wait(for: [changed], timeout: 3)
    }

    // MARK: - Answer and appearance

    func testAnswerWithoutServerShowsNotSetUp() {
        // Config/Local.xcconfig gives the test build a token but no server URL.
        openFirstPage()
        let answer = app.buttons["answerButton"]
        waitUntilEnabled(answer)
        answer.tap()

        let error = app.descendants(matching: .any)["answerError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), "The Answer sheet should fail fast without a server")
        XCTAssertTrue(element(labelContaining: "Couldn't Get an Answer").exists)
        XCTAssertTrue(element(labelContaining: "aren't set up").exists, "The message should say answers aren't set up")
        XCTAssertFalse(app.descendants(matching: .any)["answerText"].exists)

        // Try Again fails the same way instead of hanging on "Reading the page…".
        let retry = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 15))

        app.navigationBars["Answer"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Answer"])
        XCTAssertTrue(app.buttons["answerButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["1 / 2"].exists)
    }

    func testAppearancePickerSwitchesWithoutCrashing() {
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let picker = app.descendants(matching: .any)["appearancePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Appearance picker missing")

        // End on System so later tests (and the next launch) start in the default appearance.
        for option in ["Dark", "Light", "System"] {
            picker.tap()
            let choice = app.buttons[option].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(option) option missing:\n\(app.debugDescription)")
            choice.tap()
            waitForDisappearance(choice, timeout: 5)
            XCTAssertEqual(app.state, .runningForeground, "App crashed switching to \(option)")
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            let label = [picker.label, picker.value as? String ?? ""].joined(separator: " ")
            XCTAssertTrue(label.contains(option), "Picker should show \(option), shows \"\(label)\"")
        }

        app.navigationBars["Settings"].buttons["Done"].tap()
        waitForDisappearance(app.navigationBars["Settings"])
        XCTAssertTrue(documentRow.waitForExistence(timeout: 5))
    }

    // MARK: - Zoom and rotated crop

    func testZoomedPageDoesNotSwipeToNextPage() {
        openFirstPage()
        XCTAssertTrue(app.navigationBars["1 / 2"].exists)
        let page = app.descendants(matching: .any)["zoomablePage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.doubleTap()
        // Panning a zoomed page must not change pages.
        page.swipeLeft()
        XCTAssertTrue(app.navigationBars["1 / 2"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["2 / 2"].exists)
        // Back at normal size, a swipe changes the page again.
        page.doubleTap()
        page.swipeLeft()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
    }

    func testCropScreenShowsRotatedPageUpright() {
        openFirstPage()
        let window = app.windows.firstMatch.frame
        // Unrotated: the original top-left corner handle sits in the left half of the screen.
        app.buttons["cropButton"].tap()
        let handle = app.descendants(matching: .any)["cropHandle0"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        XCTAssertLessThan(handle.frame.midX, window.midX)
        app.buttons["Cancel"].tap()

        // After one clockwise turn, the original top-left corner is shown at the top right.
        let rotate = app.buttons["rotateButton"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        rotate.tap()
        waitUntilEnabled(app.buttons["cropButton"])
        app.buttons["cropButton"].tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(handle.frame.midX, window.midX)
        XCTAssertLessThan(handle.frame.midY, window.midY)
        app.buttons["cropDoneButton"].tap()
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
    }
}

/// The Adjust Borders screen after a photo import. `-uiTestingReviewImport` starts from an empty store
/// and imports two synthetic photos at launch through the real import path (the system Photos picker
/// can't be driven reliably from UI tests).
final class ScanReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Force the setting on (argument domain), so a toggle test that stopped halfway can't turn this off.
        app.launchArguments = ["-uiTestingReviewImport", "-reviewBorders", "YES"]
        app.launch()
    }

    // MARK: - Helpers

    private var saveButton: XCUIElement { app.buttons["reviewSaveButton"] }
    private func handle(_ i: Int) -> XCUIElement { app.descendants(matching: .any)["cropHandle\(i)"].firstMatch }

    /// Waits for the review screen on page 1, with its corners detected and Save usable.
    private func waitForReview(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Page 1 of 2"].waitForExistence(timeout: 20),
                      "Adjust Borders never appeared (is the setting off?):\n\(app.debugDescription)", file: file, line: line)
        XCTAssertTrue(handle(0).waitForExistence(timeout: 15), "Corner handles missing", file: file, line: line)
        waitUntilEnabled(saveButton, file: file, line: line)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 20,
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

    private func stripButton(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Page \(number)")).firstMatch
    }

    /// After Save the library opens the new document; it must hold both imported pages.
    private func assertDocumentWithTwoPages(file: StaticString = #filePath, line: UInt = #line) {
        waitForDisappearance(app.navigationBars["Page 1 of 2"], file: file, line: line)
        XCTAssertTrue(app.buttons["pageCell"].firstMatch.waitForExistence(timeout: 30), "The new document didn't open",
                      file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "pageCell").count, 2, file: file, line: line)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["documentRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "documentRow").count, 1, "Save should create exactly one document",
                       file: file, line: line)
        let twoPages = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2 pages")).firstMatch
        XCTAssertTrue(twoPages.waitForExistence(timeout: 5), "Library should show the document as 2 pages", file: file, line: line)
    }

    // MARK: - Tests

    func testReviewShowsBothPagesAndStripSwitches() {
        waitForReview()
        XCTAssertTrue(app.descendants(matching: .any)["reviewStrip"].firstMatch.exists, "Page strip missing for 2 pages")
        XCTAssertTrue(app.buttons["cropAutoButton"].exists)
        XCTAssertTrue(app.buttons["cropFullButton"].exists)
        XCTAssertTrue(app.buttons["reviewBackButton"].exists)
        XCTAssertEqual(app.buttons["reviewBackButton"].label, "Cancel", "An import offers Cancel, not Back")

        let page2 = stripButton(2)
        XCTAssertTrue(page2.waitForExistence(timeout: 5), "Strip has no Page 2 button:\n\(app.debugDescription)")
        page2.tap()
        XCTAssertTrue(app.navigationBars["Page 2 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(handle(0).waitForExistence(timeout: 15), "Page 2 never showed its corners")

        stripButton(1).tap()
        XCTAssertTrue(app.navigationBars["Page 1 of 2"].waitForExistence(timeout: 5))
    }

    func testDragCornerThenSaveCreatesTwoPageDocument() {
        waitForReview()
        let corner = handle(0)
        let before = corner.frame
        // Detected top-left corner → drag it 50 pt in toward the middle of the page.
        let start = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 50)))
        let after = corner.frame
        XCTAssertGreaterThan(after.midX - before.midX, 25, "Corner didn't follow the drag: \(before) → \(after)")
        XCTAssertGreaterThan(after.midY - before.midY, 25, "Corner didn't follow the drag: \(before) → \(after)")
        XCTAssertFalse(app.staticTexts["Corners crossed — drag them back around the page"].exists)

        waitUntilEnabled(saveButton)
        saveButton.tap()
        assertDocumentWithTwoPages()
    }

    func testCancelCreatesNoDocument() {
        waitForReview()
        app.buttons["reviewBackButton"].tap()
        waitForDisappearance(app.navigationBars["Page 1 of 2"])
        XCTAssertTrue(app.buttons["emptyImportButton"].waitForExistence(timeout: 5), "Library should be empty after Cancel")
        // Give a stray save time to land before checking nothing was created.
        XCTAssertFalse(app.buttons["documentRow"].firstMatch.waitForExistence(timeout: 3), "Cancel must not create a document")
        XCTAssertFalse(app.buttons["pageCell"].exists)
    }

    func testFullPageThenSave() {
        waitForReview()
        let corner = handle(0)
        let detected = corner.frame
        app.buttons["cropFullButton"].tap()
        // The synthetic paper starts ~16% in from the left and ~12% down: Full Page moves the corner up-left.
        let moved = expectation(for: NSPredicate { _, _ in
            corner.frame.midX < detected.midX - 10 && corner.frame.midY < detected.midY - 10
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                       "Full Page didn't move the corner out: \(detected) → \(corner.frame)")

        waitUntilEnabled(saveButton)
        saveButton.tap()
        assertDocumentWithTwoPages()
    }
}
