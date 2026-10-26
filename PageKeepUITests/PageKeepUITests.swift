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

    func testEditNotebookSurvivesRelaunch() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Edit Notebook"].tap()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        let oldName = nameField.value as? String ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        nameField.typeText("Resume Notes")
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.staticTexts["Resume Notes"].waitForExistence(timeout: 5))

        relaunchSavedLibrary()
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Resume Notes")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells.count, 1)
    }

    func testDeletingSampleStaysEmptyAfterRelaunch() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Delete Permanently"].tap()
        let confirm = app.buttons["Delete Permanently"].firstMatch
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
        showReaderActions()
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

    func testImportOpensPickerDirectlyAndCancelKeepsLibrary() throws {
        waitForLibrary()
        app.buttons["library.create"].tap()
        app.buttons["Import PDF"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "acquisition.pdfPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Scan Pages"].exists)
        app.buttons["Cancel"].firstMatch.tap()
        waitForLibrary()
        XCTAssertEqual(app.cells.count, 1)
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

    func testDiscardNotebookEditsKeepsOriginalName() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Edit Notebook"].tap()
        replaceName(with: "Discard this name")
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertEqual(app.textFields["editor.name"].value as? String, "Discard this name")
        app.buttons["editor.close"].tap()
        app.buttons["Discard Changes"].tap()
        relaunchSavedLibrary()
        openSample()
        XCTAssertTrue(app.staticTexts["Welcome to PageKeep"].exists)
        XCTAssertFalse(app.staticTexts["Discard this name"].exists)
    }

    func testArchiveAndRestoreNotebookAcrossRelaunch() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["No Notebooks Yet"].waitForExistence(timeout: 5))
        relaunchSavedLibrary()
        XCTAssertTrue(app.staticTexts["No Notebooks Yet"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
        app.buttons["settings.archive"].tap()
        let archived = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "archive.notebook.")).firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        archived.tap()
        app.buttons["archive.unarchive"].tap()
        relaunchSavedLibrary()
        openSample()
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
    }

    func testTitleSearchCanBeCleared() throws {
        waitForLibrary()
        XCTAssertFalse(app.textFields["library.search"].exists)
        app.swipeDown()
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("unmatched notebook")
        XCTAssertEqual(visibleNotebookIDs().count, 0)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "unmatched notebook".count))
        search.typeText("WELCOME")
        let found = NSPredicate { _, _ in self.visibleNotebookIDs().count == 1 }
        expectation(for: found, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "WELCOME".count))
        XCTAssertEqual(visibleNotebookIDs().count, 1)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    func testSearchCanReopenAfterCancel() throws {
        waitForLibrary()
        let search = app.textFields["library.search"]
        for _ in 0..<3 {
            XCTAssertFalse(search.exists)
            app.swipeDown()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("WELCOME")
            XCTAssertEqual(visibleNotebookIDs().count, 1)
            app.buttons["Cancel"].tap()
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertEqual(visibleNotebookIDs().count, 1)
        }
    }

    func testSettingsPersistAndCloudSyncIsUnavailable() throws {
        waitForLibrary()
        app.buttons["library.settings"].tap()
        app.buttons["settings.appearance"].tap()
        app.buttons["Dark"].tap()
        app.buttons["settings.scrolling"].tap()
        app.buttons["Horizontal"].tap()
        XCTAssertTrue(app.staticTexts["Coming in V3"].exists)
        XCTAssertFalse(app.switches["settings.cloudSync"].isEnabled)
        relaunchSavedLibrary()
        waitForLibrary()
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.buttons["settings.appearance"].label.contains("Dark")
            || app.buttons["settings.appearance"].value as? String == "Dark")
        XCTAssertTrue(app.buttons["settings.scrolling"].label.contains("Horizontal")
            || app.buttons["settings.scrolling"].value as? String == "Horizontal")
        app.buttons["Done"].tap()
        openSample()
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
    }

    func testCancelAdditionalAcquisitionPreservesEditDraft() throws {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Edit Notebook"].tap()
        replaceName(with: "Pending notebook name")
        app.buttons["editor.addPages"].tap()
        app.buttons["Scan Pages"].tap()
        let fallback = app.staticTexts["Document scanning is unavailable on this device. You can import a PDF instead."]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["editor.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["editor.name"].value as? String, "Pending notebook name")
        app.buttons["editor.close"].tap()
        app.buttons["Discard Changes"].tap()
        relaunchSavedLibrary()
        openSample()
        XCTAssertTrue(app.staticTexts["Welcome to PageKeep"].exists)
    }

    func testReaderPanelCanCollapseAndReopen() throws {
        openSample()
        XCTAssertTrue(app.buttons["viewer.share"].exists)
        XCTAssertFalse(app.buttons["viewer.panel"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["viewer.share"].waitForNonExistence(timeout: 5))
        app.buttons["viewer.panel"].tap()
        XCTAssertTrue(app.buttons["viewer.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["viewer.back"].exists)
    }

    func testPageNumberSettingPersistsAcrossRelaunch() throws {
        waitForLibrary()
        app.buttons["library.settings"].tap()
        let toggle = app.switches["settings.pageNumber"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        app.buttons["Done"].tap()
        openSample()
        XCTAssertFalse(app.staticTexts["viewer.pageNumber"].exists)
        app.buttons["viewer.actions"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["viewer.showPageNumber"].exists)

        relaunchSavedLibrary()
        waitForLibrary()
        app.buttons["library.settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        app.buttons["Done"].tap()
        openSample()
        XCTAssertTrue(app.staticTexts["viewer.pageNumber"].exists)
    }

    func testArrangePagesReorderCanBeKeptInDraftThenDiscarded() throws {
        openDraftPageArranger()
        let originalOrder = arrangedPageIDs()
        XCTAssertEqual(originalOrder.count, 3)
        guard originalOrder.count == 3 else { return }
        let first = pageElement(id: originalOrder[0])
        let last = pageElement(id: originalOrder[2])
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)))
        let expected = [originalOrder[1], originalOrder[2], originalOrder[0]]
        waitForArrangementOrder(expected)
        app.buttons["arranger.done"].tap()
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        app.buttons["editor.arrangePages"].tap()
        waitForArrangementOrder(expected)
        app.buttons["arranger.done"].tap()
        app.buttons["editor.close"].tap()
        app.buttons["Discard Changes"].tap()

        relaunchSavedLibrary()
        openPageManager()
        XCTAssertEqual(visiblePageIDs(), managerPageIDs(from: originalOrder))
    }

    func testArrangePagesDeletesSelectedPagesOnlyAfterNotebookSave() throws {
        openDraftPageArranger()
        let originalOrder = arrangedPageIDs()
        XCTAssertEqual(originalOrder.count, 3)
        guard originalOrder.count == 3 else { return }
        app.buttons["arranger.select"].tap()
        pageElement(id: originalOrder[0]).tap()
        pageElement(id: originalOrder[2]).tap()
        app.buttons["arranger.delete"].tap()
        let confirm = app.buttons["Delete Pages"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForArrangementOrder([originalOrder[1]])
        app.buttons["arranger.done"].tap()
        XCTAssertTrue(app.staticTexts["1 page"].waitForExistence(timeout: 5))
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.buttons["viewer.actions"].waitForExistence(timeout: 5))

        relaunchSavedLibrary()
        openPageManager()
        XCTAssertEqual(visiblePageIDs(), managerPageIDs(from: [originalOrder[1]]))
    }

    func testArrangePagesMovesMultiplePagesTogetherAndSavesOrder() throws {
        openDraftPageArranger()
        let originalOrder = arrangedPageIDs()
        XCTAssertEqual(originalOrder.count, 3)
        guard originalOrder.count == 3 else { return }
        app.buttons["arranger.select"].tap()
        pageElement(id: originalOrder[0]).tap()
        pageElement(id: originalOrder[2]).tap()
        app.buttons["arranger.move"].tap()
        app.buttons["arranger.destination.cancel"].tap()
        XCTAssertEqual(arrangedPageIDs(), originalOrder)
        app.buttons["arranger.move"].tap()
        app.buttons["arranger.destination.end"].tap()
        let expected = [originalOrder[1], originalOrder[0], originalOrder[2]]
        waitForArrangementOrder(expected)
        app.buttons["arranger.done"].tap()
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.buttons["viewer.actions"].waitForExistence(timeout: 5))

        relaunchSavedLibrary()
        openPageManager()
        XCTAssertEqual(visiblePageIDs(), managerPageIDs(from: expected))
    }

    func testRepeatedNotebookTapNeedsOnlyOneBackAction() {
        waitForLibrary()
        app.cells.firstMatch.doubleTap()
        let back = app.buttons["viewer.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        waitForLibrary()
        XCTAssertFalse(app.buttons["viewer.back"].exists)
    }

    func testRepeatedManageActionReturnsToTheSameReader() {
        openSample()
        app.buttons["viewer.manage"].doubleTap()
        XCTAssertTrue(app.buttons["manager.select"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["manager.select"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["viewer.back"].exists)
        app.buttons["viewer.back"].tap()
        waitForLibrary()
    }

    func testChangedEditorSwipeOffersKeepEditingAndDiscard() {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Edit Notebook"].tap()
        replaceName(with: "Unsaved swipe edit")
        app.navigationBars["Edit Notebook"].swipeDown()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertEqual(app.textFields["editor.name"].value as? String, "Unsaved swipe edit")
        app.buttons["editor.close"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["viewer.back"].waitForExistence(timeout: 5))
    }

    private func openDraftPageArranger() {
        openSample()
        app.buttons["viewer.actions"].tap()
        app.buttons["Edit Notebook"].tap()
        let arrange = app.buttons["editor.arrangePages"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 5))
        XCTAssertTrue(arrange.isEnabled)
        arrange.tap()
        XCTAssertTrue(app.buttons["arranger.done"].waitForExistence(timeout: 5))
    }

    private func arrangedPageIDs() -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "arranger.page."))
            .allElementsBoundByIndex
        var ids: [String] = []
        for row in rows where !ids.contains(row.identifier) { ids.append(row.identifier) }
        return ids
    }

    private func waitForArrangementOrder(_ expected: [String]) {
        expectation(for: NSPredicate { _, _ in self.arrangedPageIDs() == expected }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
    }

    private func managerPageIDs(from arrangedIDs: [String]) -> [String] {
        arrangedIDs.map { $0.replacingOccurrences(of: "arranger.page.", with: "manager.page.") }
    }

    private func replaceName(with name: String) {
        let field = app.textFields["editor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        field.typeText(name)
    }

    private func showReaderActions() {
        if app.buttons["viewer.manage"].exists { return }
        let panel = app.buttons["viewer.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.tap()
    }

    private func visibleNotebookIDs() -> [String] {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.notebook.")).allElementsBoundByIndex
        return Array(Set(matches.map(\.identifier)))
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
        showReaderActions()
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
