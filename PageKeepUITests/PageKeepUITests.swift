import XCTest

final class PageKeepUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-tests"]
        app.launch()
    }

    func testSampleOpensAndSurvivesRelaunch() throws {
        waitForLibrary()
        XCTAssertEqual(app.cells.count, 1)
        attachScreenshot(named: "Notebook library")
        openSample()
        XCTAssertTrue(app.buttons["viewer.share"].exists)
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
        attachScreenshot(named: "Notebook reader")

        relaunchSavedLibrary()
        waitForLibrary()
        XCTAssertEqual(app.cells.count, 1)
    }

    func testRenameSurvivesRelaunch() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Rename"].tap()
        let nameField = app.textFields["rename.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        let oldName = nameField.value as? String ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        nameField.typeText("Resume Notes")
        app.buttons["rename.save"].tap()
        XCTAssertTrue(app.navigationBars["Resume Notes"].waitForExistence(timeout: 5))

        relaunchSavedLibrary()
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Resume Notes")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells.count, 1)
    }

    func testDeletingSampleStaysEmptyAfterRelaunch() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Delete Notebook"].tap()
        let confirm = app.buttons["Delete Notebook"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No Notebooks Yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan Pages"].exists)
        XCTAssertTrue(app.buttons["Import PDF"].exists)
        attachScreenshot(named: "Empty library")

        relaunchSavedLibrary()
        XCTAssertTrue(app.staticTexts["No Notebooks Yet"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells.count, 0)
    }

    func testSelectRotateAndDeleteAllPages() throws {
        openPageManager()
        app.buttons["manager.select"].tap()
        app.buttons["manager.selectAll"].tap()
        XCTAssertTrue(app.staticTexts["3 selected"].exists)
        app.buttons["manager.select"].tap()
        XCTAssertFalse(app.buttons["manager.selectAll"].exists)
        app.buttons["manager.select"].tap()
        XCTAssertTrue(app.staticTexts["0 selected"].exists)
        app.buttons["manager.selectAll"].tap()
        let rotate = app.buttons["manager.rotate"]
        XCTAssertTrue(rotate.isEnabled)
        rotate.tap()
        waitUntilEnabled(rotate)
        XCTAssertTrue(app.staticTexts["3 selected"].exists)
        attachScreenshot(named: "Selected pages")
        app.buttons["manager.delete"].tap()
        let confirm = app.buttons["Delete Pages"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No Pages"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No Pages Yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["viewer.share"].isEnabled)
        XCTAssertTrue(app.buttons["viewer.add"].isEnabled)

        relaunchSavedLibrary()
        waitForLibrary()
        XCTAssertEqual(app.cells.count, 1)
        openSample()
        XCTAssertTrue(app.staticTexts["No Pages Yet"].waitForExistence(timeout: 5))
    }

    func testReorderPagesSurvivesRelaunch() throws {
        openPageManager()
        XCTAssertEqual(app.segmentedControls.count, 0)
        let originalOrder = visiblePageIDs()
        XCTAssertEqual(originalOrder.count, 3)
        guard originalOrder.count == 3 else { return }
        let first = pageElement(id: originalOrder[0])
        let last = pageElement(id: originalOrder[2])
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)))
        let expectedOrder = [originalOrder[1], originalOrder[2], originalOrder[0]]
        let orderSaved = NSPredicate { _, _ in self.visiblePageIDs() == expectedOrder }
        expectation(for: orderSaved, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        attachScreenshot(named: "Reordered pages")

        relaunchSavedLibrary()
        openPageManager()
        XCTAssertEqual(visiblePageIDs(), expectedOrder)
        pageElement(id: originalOrder[0]).tap()
        XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["manager.select"].exists)
    }

    func testSharePresentsSystemSheet() throws {
        openSample()
        app.buttons["viewer.share"].tap()
        let share = app.descendants(matching: .any).matching(identifier: "share.sheet").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        attachScreenshot(named: "Share PDF")
    }

    func testSimulatorScannerProvidesImportFallback() throws {
        waitForLibrary()
        app.buttons["library.create"].tap()
        app.buttons["Scan Pages"].tap()
        let fallback = app.staticTexts["Document scanning is unavailable on this device. You can import a PDF instead."]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import PDF"].isEnabled)
        attachScreenshot(named: "Scanner fallback")
        app.buttons["Cancel"].tap()
        waitForLibrary()
        XCTAssertEqual(app.cells.count, 1)
    }

    private func waitForLibrary() {
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 15))
        let loaded = NSPredicate { _, _ in self.app.cells.count == 1 }
        expectation(for: loaded, evaluatedWith: app)
        waitForExpectations(timeout: 15)
    }

    private func openSample() {
        waitForLibrary()
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer.manage"].waitForExistence(timeout: 5))
    }

    private func openPageManager() {
        openSample()
        app.buttons["viewer.manage"].tap()
        XCTAssertTrue(app.buttons["manager.select"].waitForExistence(timeout: 5))
    }

    private func relaunchSavedLibrary() {
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        expectation(for: NSPredicate { _, _ in element.isEnabled }, evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    private func visiblePageIDs() -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "manager.page."))
            .allElementsBoundByIndex
        var ids: [String] = []
        for row in rows where !ids.contains(row.identifier) {
            ids.append(row.identifier)
        }
        return ids
    }

    private func pageElement(id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
