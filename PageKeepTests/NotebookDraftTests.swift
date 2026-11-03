import XCTest
import PDFKit
import CoreGraphics
@testable import PageKeep

@MainActor
final class NotebookDraftTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookDraftTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCanceledChildLeavesParentBatchesAndFieldsIntact() async throws {
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library"))
        let first = try await repository.prepareImport(from: makePDF(named: "first"))
        let parent = NotebookDraft(details: NotebookDetails(name: "Math"), additions: [first])
        parent.details.colorID = "green"
        let child = NotebookDraft(details: parent.details)
        let childPages = try await repository.prepareImport(from: makePDF(named: "child"))
        child.add(childPages)
        await child.discardPendingPages(in: repository)

        XCTAssertEqual(parent.details.colorID, "green")
        XCTAssertEqual(parent.additions.map(\.id), [first.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: childPages.url.path))
        await parent.discardPendingPages(in: repository)
    }

    func testDiscardRemovesEveryOwnedBatchAndDoesNotCreateNotebook() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let existingIDs = store.notebooks.map(\.id)
        let first = try await store.repository.prepareImport(from: makePDF(named: "first"))
        let second = try await store.repository.prepareImport(from: makePDF(named: "second"))
        let draft = NotebookDraft(details: NotebookDetails(name: "Unsaved"), additions: [first])
        draft.add(second)
        XCTAssertEqual(draft.pendingPageCount, 2)
        await draft.discardPendingPages(in: store.repository)

        XCTAssertTrue(draft.additions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(store.notebooks.map(\.id), existingIDs)
    }

    func testFailedSaveRetainsAllBatchesAndRetryCommitsThenCleansThem() async throws {
        let failure = DraftFailureSwitch()
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library")) { checkpoint in
            if case .beforeManifestCommit = checkpoint, failure.isEnabled { throw DraftFailure.injected }
        }
        let store = LibraryStore(repository: repository)
        await store.load()
        let first = try await repository.prepareImport(from: makePDF(named: "first"))
        let second = try await repository.prepareImport(from: makePDF(named: "second"))
        let draft = NotebookDraft(details: NotebookDetails(name: "Draft", symbolName: "leaf", colorID: "green"), additions: [first])
        draft.add(second)
        let original = store.notebooks
        failure.isEnabled = true
        do {
            _ = try await draft.save(in: store, notebookID: nil)
            XCTFail("Expected the save to fail")
        } catch DraftFailure.injected { }
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(draft.additions.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.notebooks, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))

        failure.isEnabled = false
        let result = try await draft.save(in: store, notebookID: nil)
        let notebook = try XCTUnwrap(store.notebook(id: result.notebookID))
        XCTAssertEqual(notebook.pageCount, 2)
        XCTAssertEqual(notebook.symbolName, "leaf")
        XCTAssertEqual(notebook.colorID, "green")
        XCTAssertEqual(result.firstAddedPageID, notebook.pages.first?.id)
        XCTAssertTrue(draft.additions.isEmpty)
        XCTAssertFalse(draft.isSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testSecondSaveCannotClearSavingStateOrDiscardFirstSavePages() async throws {
        let barrier = DraftSaveBarrier()
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library")) { checkpoint in
            if case .beforeManifestCommit = checkpoint { barrier.waitIfEnabled() }
        }
        let store = LibraryStore(repository: repository)
        await store.load()
        let prepared = try await repository.prepareImport(from: makePDF(named: "first"))
        let draft = NotebookDraft(details: NotebookDetails(name: "Draft"), additions: [prepared])
        barrier.enable()
        defer { barrier.release() }
        let firstSave = Task { try await draft.save(in: store, notebookID: nil) }
        let deadline = Date().addingTimeInterval(5)
        while !barrier.hasReachedCommit && Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(barrier.hasReachedCommit)
        XCTAssertTrue(draft.isSaving)
        do {
            _ = try await draft.save(in: store, notebookID: nil)
            XCTFail("A second save should be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This notebook is already being saved. Please wait.")
        }
        XCTAssertTrue(draft.isSaving)
        XCTAssertThrowsError(try draft.reorderPages(orderedIDs: draft.pages.map(\.id)))
        XCTAssertThrowsError(try draft.removePages(ids: Set(draft.pages.map(\.id))))
        XCTAssertThrowsError(try draft.movePages(ids: [], before: nil))
        await draft.discardPendingPages(in: repository)
        XCTAssertEqual(draft.additions.map(\.id), [prepared.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        barrier.release()
        let saved = try await firstSave.value
        XCTAssertNotNil(store.notebook(id: saved.notebookID))
        XCTAssertFalse(draft.isSaving)
        XCTAssertTrue(draft.additions.isEmpty)
    }

    func testMetadataChangesRequireConfirmationButUnchangedDraftDoesNot() {
        let draft = NotebookDraft(details: NotebookDetails(name: "Math"))
        XCTAssertFalse(draft.hasChanges)
        draft.details.symbolName = "leaf"
        XCTAssertTrue(draft.hasChanges)
        draft.details.symbolName = "book.closed"
        XCTAssertFalse(draft.hasChanges)
    }

    func testMoveSelectedPagesPreservesTheirRelativeOrderAndDeletionStaysInDraft() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let saved = try XCTUnwrap(store.notebooks.first)
        let prepared = try await store.repository.prepareImport(from: makePDF(named: "incoming"))
        let draft = NotebookDraft(details: saved.details, additions: [prepared], existingNotebook: saved)
        let original = draft.pages
        XCTAssertEqual(draft.pageCount, 4)
        XCTAssertEqual(draft.pendingPageCount, 1)
        try draft.movePages(ids: [original[0].id, original[2].id], before: original[1].id)
        XCTAssertEqual(draft.pages.map(\.id), [original[0].id, original[2].id, original[1].id, original[3].id])
        try draft.movePages(ids: [original[0].id, original[2].id], before: nil)
        XCTAssertEqual(draft.pages.map(\.id), [original[1].id, original[3].id, original[0].id, original[2].id])
        try draft.removePages(ids: [original[1].id, original[3].id])
        XCTAssertEqual(draft.pageCount, 2)
        XCTAssertEqual(draft.pendingPageCount, 0)
        XCTAssertTrue(draft.pageLayoutChanged)
        XCTAssertEqual(store.notebook(id: saved.id), saved)
        await draft.discardPendingPages(in: store.repository)
        XCTAssertEqual(store.notebook(id: saved.id), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
        let reloaded = try await store.repository.load()
        XCTAssertEqual(reloaded.manifest.notebooks.first, saved)
    }

    func testRestoringOriginalLayoutKeepsSingleImportByteExact() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        // Use the sample's three-page PDF as one imported batch.
        let sample = try XCTUnwrap(store.notebooks.first)
        let imported = try await store.repository.prepareImport(from: XCTUnwrap(store.pdfURL(for: sample)))
        let bytes = try Data(contentsOf: imported.url)
        let draft = NotebookDraft(details: NotebookDetails(name: "Unchanged import"), additions: [imported])
        let original = draft.pages
        try draft.reorderPages(orderedIDs: original.reversed().map(\.id))
        XCTAssertTrue(draft.pageLayoutChanged)
        try draft.reorderPages(orderedIDs: original.map(\.id))
        XCTAssertFalse(draft.pageLayoutChanged)
        let result = try await draft.save(in: store, notebookID: nil)
        let notebook = try XCTUnwrap(store.notebook(id: result.notebookID))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.pdfURL(for: notebook))), bytes)
    }

    func testArrangedSaveFailureRetainsPlanAndRetryKeepsIDs() async throws {
        let failure = DraftFailureSwitch()
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library")) { checkpoint in
            if case .beforeManifestCommit = checkpoint, failure.isEnabled { throw DraftFailure.injected }
        }
        let store = LibraryStore(repository: repository)
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let first = try await repository.prepareImport(from: makePDF(named: "first"))
        let second = try await repository.prepareImport(from: makePDF(named: "second"))
        let draft = NotebookDraft(details: sample.details, additions: [first, second], existingNotebook: sample)
        let incomingIDs = Array(draft.pages.suffix(2)).map(\.id)
        try draft.movePages(ids: Set(incomingIDs), before: draft.pages[0].id)
        try draft.removePages(ids: [sample.pages[1].id])
        draft.details.name = "Arranged"
        let plan = draft.pages
        failure.isEnabled = true
        do { _ = try await draft.save(in: store, notebookID: sample.id); XCTFail("Expected failure") }
        catch DraftFailure.injected { }
        XCTAssertEqual(draft.pages, plan)
        XCTAssertEqual(draft.additions.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.notebook(id: sample.id), sample)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        failure.isEnabled = false
        let result = try await draft.save(in: store, notebookID: sample.id)
        let saved = try XCTUnwrap(store.notebook(id: sample.id))
        XCTAssertEqual(saved.pages.map(\.id), plan.map(\.id))
        XCTAssertEqual(result.firstAddedPageID, incomingIDs[0])
        XCTAssertEqual(saved.name, "Arranged")
        XCTAssertTrue(draft.additions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testAllNewPagesDeletedCannotSaveAndInvalidMovesDoNotChangeDraft() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let prepared = try await store.repository.prepareImport(from: makePDF(named: "first"))
        let draft = NotebookDraft(details: NotebookDetails(name: "New"), additions: [prepared])
        let original = draft.pages
        XCTAssertThrowsError(try draft.reorderPages(orderedIDs: [UUID()]))
        XCTAssertThrowsError(try draft.movePages(ids: [original[0].id], before: original[0].id))
        XCTAssertThrowsError(try draft.removePages(ids: [UUID()]))
        XCTAssertEqual(draft.pages, original)
        try draft.removePages(ids: [original[0].id])
        XCTAssertEqual(draft.pendingPageCount, 0)
        do { _ = try await draft.save(in: store, notebookID: nil); XCTFail("Expected retained pages") }
        catch PDFError.emptyDocument { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        await draft.discardPendingPages(in: store.repository)
    }

    func testStaleArrangementPreservesBothSavedAndDraftPDFs() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let draft = NotebookDraft(details: sample.details, existingNotebook: sample)
        try draft.reorderPages(orderedIDs: sample.pages.reversed().map(\.id))
        let plan = draft.pages
        let incoming = try await store.repository.prepareImport(from: makePDF(named: "later"))
        defer { PDFService.discard(incoming) }
        _ = try await store.appendPrepared(incoming, to: sample.id)
        let newer = try XCTUnwrap(store.notebook(id: sample.id))
        XCTAssertEqual(newer.pageCount, 4)
        let result = try await draft.save(in: store, notebookID: sample.id)
        let saved = try XCTUnwrap(store.notebook(id: result.notebookID))
        XCTAssertEqual(saved.pages.map(\.id), plan.map(\.id))
        XCTAssertTrue(store.notebooks.contains { $0.contentVersionID == newer.contentVersionID })
        XCTAssertEqual(store.notebooks.count, 2)
        XCTAssertEqual(store.syncNotices.filter { $0.kind == .conflict }.count, 1)
        let reopened = try await store.repository.load()
        XCTAssertEqual(Set(reopened.manifest.notebooks.map(\.contentVersionID)), Set(store.notebooks.map(\.contentVersionID)))
    }

    func testRotationWithSamePageIDsCannotSilentlyReplaceActiveDraftSource() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let source = try XCTUnwrap(store.pdfURL(for: sample))
        let draft = NotebookDraft(details: sample.details, existingNotebook: sample, savedURL: source)
        let pinned = try XCTUnwrap(draft.pinnedPDFURL)
        let sourceBytes = try Data(contentsOf: pinned)
        try draft.reorderPages(orderedIDs: sample.pages.reversed().map(\.id))
        try await store.rotatePages(in: sample.id, ids: [sample.pages[0].id])
        let rotated = try XCTUnwrap(store.notebook(id: sample.id))
        XCTAssertEqual(rotated.pages, sample.pages)
        XCTAssertNotEqual(rotated.contentVersionID, sample.contentVersionID)
        XCTAssertEqual(try Data(contentsOf: pinned), sourceBytes)
        let result = try await draft.save(in: store, notebookID: sample.id)
        let arranged = try XCTUnwrap(store.notebook(id: result.notebookID))
        XCTAssertEqual(arranged.pages.map(\.id), sample.pages.reversed().map(\.id))
        XCTAssertTrue(store.notebooks.contains { $0.contentVersionID == rotated.contentVersionID })
        XCTAssertEqual(store.notebooks.count, 2)
    }

    func testDraftMetadataSaveOnlyChangesFieldsEditedInDraft() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let draft = NotebookDraft(details: sample.details, existingNotebook: sample)
        draft.details.name = "My edit"
        var remoteDetails = sample.details
        remoteDetails.colorID = "green"
        _ = try await store.repository.edit(sample.id, details: remoteDetails, appending: [])
        await store.reload()
        _ = try await draft.save(in: store, notebookID: sample.id)
        let saved = try XCTUnwrap(store.notebook(id: sample.id))
        XCTAssertEqual(saved.name, "My edit")
        XCTAssertEqual(saved.colorID, "green")
        XCTAssertEqual(saved.revisionID, sample.revisionID)
        XCTAssertEqual(store.notebooks.count, 1)
    }

    func testDeletedNotebookRecoversChangedDraftButUnchangedDraftStaysDeleted() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let unchanged = NotebookDraft(details: sample.details, existingNotebook: sample)
        let edited = NotebookDraft(details: sample.details, existingNotebook: sample, savedURL: store.pdfURL(for: sample))
        edited.details.colorID = "green"
        try await store.deleteNotebook(sample.id)
        do { _ = try await unchanged.save(in: store, notebookID: sample.id); XCTFail("An unchanged draft must stay deleted") }
        catch LibraryError.notebookNotFound { }
        XCTAssertTrue(store.notebooks.isEmpty)
        let result = try await edited.save(in: store, notebookID: sample.id)
        let recovered = try XCTUnwrap(store.notebook(id: result.notebookID))
        XCTAssertNotEqual(recovered.id, sample.id)
        XCTAssertTrue(recovered.name.hasSuffix("(Recovered)"))
        XCTAssertEqual(recovered.colorID, "green")
        XCTAssertEqual(recovered.revisionID, sample.revisionID)
        let snapshot = try await store.repository.syncSnapshot()
        XCTAssertEqual(snapshot.sync.tombstones.map(\.id), [sample.id])
    }

    func testPinnedSourceRemainsUsableAfterAcknowledgedOldRevisionIsCleaned() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let source = try XCTUnwrap(store.pdfURL(for: sample))
        let draft = NotebookDraft(details: sample.details, existingNotebook: sample, savedURL: source)
        let pinned = try XCTUnwrap(draft.pinnedPDFURL)
        try await store.rotatePages(in: sample.id, ids: [sample.pages[0].id])
        try await store.rotatePages(in: sample.id, ids: [sample.pages[0].id])
        let pending = try await store.repository.syncSnapshot()
        try await store.acknowledgeSyncEntries(Set(pending.sync.outbox.map(\.id)))
        try await store.acknowledgeSyncEntries([])
        await store.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        let document = try PDFService.validate(at: pinned)
        XCTAssertEqual(document.pageCount, sample.pageCount)
    }

    private func makePDF(named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}

private enum DraftFailure: Error {
    case injected
}

private final class DraftFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
}

private final class DraftSaveBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var enabled = false
    private var reached = false

    var hasReachedCommit: Bool { lock.withLock { reached } }

    func enable() { lock.withLock { enabled = true } }
    func release() { semaphore.signal() }

    func waitIfEnabled() {
        let shouldWait = lock.withLock {
            guard enabled else { return false }
            reached = true
            return true
        }
        if shouldWait { _ = semaphore.wait(timeout: .now() + 5) }
    }
}
