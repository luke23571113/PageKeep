import XCTest
@testable import PageKeep

@MainActor
final class ReadingPositionStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ReadingPositionStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testPageIdentityPersistsAndSurvivesReordering() {
        let notebookID = UUID()
        let pages = [UUID(), UUID(), UUID()]
        let store = ReadingPositionStore(defaults: defaults)
        store.remember(pageID: pages[1], in: pages, for: notebookID)

        let restored = ReadingPositionStore(defaults: defaults)
        XCTAssertEqual(restored.pageID(for: notebookID, in: [pages[1], pages[2], pages[0]]), pages[1])
    }

    func testRemovedPageUsesItsPreviousIndexAndClampsToLastPage() {
        let notebookID = UUID()
        let pages = [UUID(), UUID(), UUID(), UUID()]
        let store = ReadingPositionStore(defaults: defaults)
        store.remember(pageID: pages[2], in: pages, for: notebookID)
        XCTAssertEqual(store.pageID(for: notebookID, in: [pages[0], pages[1], pages[3]]), pages[3])
        XCTAssertEqual(store.pageID(for: notebookID, in: [pages[0], pages[1]]), pages[1])
    }

    func testExplicitValidPageTakesPriorityAndInvalidRequestUsesMemory() {
        let notebookID = UUID()
        let pages = [UUID(), UUID(), UUID()]
        let store = ReadingPositionStore(defaults: defaults)
        store.remember(pageID: pages[1], in: pages, for: notebookID)
        XCTAssertEqual(store.pageID(for: notebookID, in: pages, requestedPageID: pages[2]), pages[2])
        XCTAssertEqual(store.pageID(for: notebookID, in: pages, requestedPageID: UUID()), pages[1])
    }

    func testNotebooksAndDeviceDefaultsRemainIndependent() throws {
        let notebookID = UUID()
        let pages = [UUID(), UUID()]
        let store = ReadingPositionStore(defaults: defaults)
        store.remember(pageID: pages[1], in: pages, for: notebookID)
        XCTAssertEqual(store.pageID(for: UUID(), in: pages), pages[0])

        let otherSuite = "ReadingPositionStoreTests-\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        XCTAssertEqual(ReadingPositionStore(defaults: otherDefaults).pageID(for: notebookID, in: pages), pages[0])
    }

    func testEmptyPagesAndInvalidUpdatesKeepTheLastUsefulPosition() {
        let notebookID = UUID()
        let pages = [UUID(), UUID()]
        let store = ReadingPositionStore(defaults: defaults)
        store.remember(pageID: pages[1], in: pages, for: notebookID)
        store.remember(pageID: nil, in: [], for: notebookID)
        store.remember(pageID: UUID(), in: pages, for: notebookID)
        XCTAssertNil(store.pageID(for: notebookID, in: []))
        XCTAssertEqual(store.pageID(for: notebookID, in: pages), pages[1])
    }

    func testCorruptSavedPositionFallsBackToFirstPage() {
        defaults.set(Data("invalid".utf8), forKey: ReadingPositionStore.positionsKey)
        let pages = [UUID(), UUID()]
        XCTAssertEqual(ReadingPositionStore(defaults: defaults).pageID(for: UUID(), in: pages), pages[0])
    }
}
