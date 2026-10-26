import XCTest
@testable import PageKeep

@MainActor
final class NotebookPresentationTests: XCTestCase {
    func testRepeatedRequestsKeepTheOriginalSheetUntilDismissalCompletes() {
        let presentation = NotebookPresentation()
        presentation.show(.settings)
        let originalID = presentation.sheet?.id
        presentation.show(.edit(UUID()))
        XCTAssertEqual(presentation.sheet?.id, originalID)

        presentation.sheet = nil
        presentation.show(.settings)
        XCTAssertNil(presentation.sheet)
        presentation.didDismiss()
        presentation.show(.settings)
        XCTAssertNotNil(presentation.sheet)
        XCTAssertNotEqual(presentation.sheet?.id, originalID)
    }

    func testNavigationIsDeliveredOnlyAfterSheetDismissal() {
        let presentation = NotebookPresentation()
        let notebookID = UUID()
        let pageID = UUID()
        presentation.show(.manage(notebookID))
        presentation.finish(opening: notebookID, pageID: pageID)
        XCTAssertNil(presentation.sheet)
        let destination = presentation.didDismiss()
        XCTAssertEqual(destination?.notebookID, notebookID)
        XCTAssertEqual(destination?.pageID, pageID)
        XCTAssertNil(presentation.didDismiss())
    }

    func testMetadataOnlySaveDoesNotNavigateAndStaleCompletionCannotDismissNextSheet() {
        let presentation = NotebookPresentation()
        presentation.show(.edit(UUID()))
        let oldID = presentation.sheet!.id
        presentation.finish(requestID: oldID)
        XCTAssertNil(presentation.didDismiss())
        presentation.show(.settings)
        let currentID = presentation.sheet?.id
        presentation.finish(opening: UUID(), requestID: oldID)
        XCTAssertEqual(presentation.sheet?.id, currentID)
    }

    func testLeavingReaderCancelsShareBeforeItCanPresent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: root.appendingPathComponent("Library")))
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        let presentation = NotebookPresentation()
        presentation.share(notebook, store: store)
        presentation.cancelPreparation()
        presentation.show(.settings)
        let settingsID = presentation.sheet?.id
        await Task.yield()
        XCTAssertEqual(presentation.sheet?.id, settingsID)
        XCTAssertNil(presentation.errorMessage)
    }

    func testRepeatedNavigationDoesNotPushTheNotebookAgain() {
        let navigation = LibraryNavigation()
        let id = UUID()
        navigation.open(id)
        navigation.open(id)
        XCTAssertEqual(navigation.path, [id])
        let page = UUID()
        navigation.open(id, pageID: page)
        XCTAssertEqual(navigation.path, [id])
        XCTAssertEqual(navigation.requestedPageID, page)
        let requestID = navigation.selectionRequestID
        navigation.open(id, pageID: page)
        XCTAssertNotEqual(navigation.selectionRequestID, requestID)
    }
}

@MainActor
final class SearchPullStateTests: XCTestCase {
    func testReadinessSurvivesSpringBackUntilRelease() {
        var pull = SearchPullState()
        pull.updateWidth(400)
        pull.updatePosition(100, isEnabled: true)
        pull.drag(startX: 100, horizontal: 0, vertical: 90, isEnabled: true)
        pull.updatePosition(180, isEnabled: true)
        pull.updatePosition(100, isEnabled: true)
        XCTAssertTrue(pull.release())
        XCTAssertFalse(pull.release())
    }

    func testReorderHandlesHorizontalSwipesAndShortPullsDoNotOpenSearch() {
        for gesture in [(380.0, 0.0, 100.0), (100.0, 50.0, 100.0), (100.0, 0.0, 20.0)] {
            var pull = SearchPullState()
            pull.updateWidth(400)
            pull.updatePosition(100, isEnabled: true)
            pull.drag(startX: gesture.0, horizontal: gesture.1, vertical: gesture.2, isEnabled: true)
            pull.updatePosition(200, isEnabled: true)
            XCTAssertFalse(pull.release())
        }
    }

    func testNewBaselineDoesNotCountLayoutMovementAsAPull() {
        var pull = SearchPullState()
        pull.updateWidth(400)
        pull.updatePosition(100, isEnabled: true)
        pull.reset(includingBaseline: true)
        pull.updatePosition(250, isEnabled: true)
        pull.drag(startX: 100, horizontal: 0, vertical: 40, isEnabled: true)
        pull.updatePosition(290, isEnabled: true)
        XCTAssertFalse(pull.release())
    }
}
