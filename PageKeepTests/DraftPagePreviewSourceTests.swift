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
        let sources = DraftPagePreviewSources(notebook: notebook, savedURL: savedURL, additions: [])
        let source = try XCTUnwrap(sources.source(for: draft.pages[0]))
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
        let sources = DraftPagePreviewSources(
            notebook: notebook,
            savedURL: URL(fileURLWithPath: "/Library/saved.pdf"),
            additions: draft.additions
        )
        let source = try XCTUnwrap(sources.source(for: draft.pages[0]))
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
        let sources = DraftPagePreviewSources(notebook: notebook, savedURL: savedURL, additions: [batch])
        XCTAssertNil(sources.source(for: unknownSaved))
        XCTAssertNil(sources.source(for: unknownBatch))
        XCTAssertNil(sources.source(for: invalidIndex))
        let saved = DraftPage(id: notebook.pages[0].id, source: .existing(notebook.pages[0].id))
        let missingFile = DraftPagePreviewSources(notebook: notebook, savedURL: nil, additions: [])
        XCTAssertNil(missingFile.source(for: saved))
    }

    private func makeNotebook() -> Notebook {
        Notebook(id: UUID(), name: "Math", createdAt: .distantPast, modifiedAt: .distantPast, revisionID: UUID(), pages: [NotebookPage(), NotebookPage(), NotebookPage()])
    }
}
