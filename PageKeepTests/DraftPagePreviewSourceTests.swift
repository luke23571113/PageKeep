import XCTest
@testable import PageKeep

@MainActor
final class DraftPagePreviewSourceTests: XCTestCase {
    func testExistingPageThumbnailUsesSavedIndexAfterDraftReordering() throws {
        let notebook = makeNotebook()
        let savedURL = URL(fileURLWithPath: "/Library/saved.pdf")
        let draft = NotebookDraft(details: notebook.details, existingNotebook: notebook)
        let originalIDs = draft.pages.map(\.id)
        try draft.reorderPages(orderedIDs: [originalIDs[2], originalIDs[0], originalIDs[1]])
        let source = try XCTUnwrap(DraftPagePreviewSource(page: draft.pages[0], notebook: notebook, savedURL: savedURL, additions: []))
        XCTAssertEqual(source.url, savedURL)
        XCTAssertEqual(source.pageIndex, 2)
    }

    func testPendingPageThumbnailKeepsBatchAndSourceIndexAfterMixedMove() throws {
        let notebook = makeNotebook()
        let first = PreparedPDF(url: URL(fileURLWithPath: "/Staging/first.pdf"), suggestedName: "First", pageCount: 2)
        let second = PreparedPDF(url: URL(fileURLWithPath: "/Staging/second.pdf"), suggestedName: "Second", pageCount: 3)
        let draft = NotebookDraft(details: notebook.details, additions: [first, second], existingNotebook: notebook)
        let last = try XCTUnwrap(draft.pages.last)
        try draft.movePages(ids: [last.id], before: draft.pages.first?.id)
        let source = try XCTUnwrap(DraftPagePreviewSource(page: draft.pages[0], notebook: notebook, savedURL: URL(fileURLWithPath: "/Library/saved.pdf"), additions: draft.additions))
        XCTAssertEqual(source.url, second.url)
        XCTAssertEqual(source.pageIndex, 2)
    }

    func testMissingOrInvalidSourceDoesNotShowAnotherPage() {
        let notebook = makeNotebook()
        let savedURL = URL(fileURLWithPath: "/Library/saved.pdf")
        let batch = PreparedPDF(url: URL(fileURLWithPath: "/Staging/first.pdf"), suggestedName: "First", pageCount: 2)
        let unknownSaved = DraftPage(id: UUID(), source: .existing(UUID()))
        let unknownBatch = DraftPage(id: UUID(), source: .prepared(UUID(), 0))
        let invalidIndex = DraftPage(id: UUID(), source: .prepared(batch.id, 2))
        XCTAssertNil(DraftPagePreviewSource(page: unknownSaved, notebook: notebook, savedURL: savedURL, additions: [batch]))
        XCTAssertNil(DraftPagePreviewSource(page: unknownBatch, notebook: notebook, savedURL: savedURL, additions: [batch]))
        XCTAssertNil(DraftPagePreviewSource(page: invalidIndex, notebook: notebook, savedURL: savedURL, additions: [batch]))
        let saved = DraftPage(id: notebook.pages[0].id, source: .existing(notebook.pages[0].id))
        XCTAssertNil(DraftPagePreviewSource(page: saved, notebook: notebook, savedURL: nil, additions: []))
    }

    private func makeNotebook() -> Notebook {
        Notebook(id: UUID(), name: "Math", createdAt: .distantPast, modifiedAt: .distantPast, revisionID: UUID(), pages: [NotebookPage(), NotebookPage(), NotebookPage()])
    }
}
