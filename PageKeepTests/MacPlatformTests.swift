import XCTest
import PDFKit
@testable import PageKeep

@MainActor
final class MacPlatformTests: XCTestCase {
    func testEditorImportProtectsUnchangedDraftAndDiscardRemovesPreparedFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        try PDFService.writeSample(to: source)
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library"))
        let session = MacEditorSession(notebookID: UUID(), draft: NotebookDraft(details: NotebookDetails(name: "Notes")))
        var errors: [String] = []
        XCTAssertFalse(session.hasPendingChanges)
        let task = try XCTUnwrap(session.importPDF(from: source, in: repository) { errors.append($0) })
        XCTAssertTrue(session.hasPendingChanges)
        await task.value
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(session.draft.pageCount, 3)
        let prepared = try XCTUnwrap(session.draft.additions.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        await session.discard(in: repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
        XCTAssertFalse(session.hasPendingChanges)
    }

    func testDiscardedEditorCannotReceivePendingImportOrError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        try PDFService.writeSample(to: source)
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library"))
        let session = MacEditorSession(notebookID: UUID(), draft: NotebookDraft(details: NotebookDetails(name: "Notes")))
        var errors: [String] = []
        let task = try XCTUnwrap(session.importPDF(from: source, in: repository) { errors.append($0) })
        await session.discard(in: repository)
        await task.value
        XCTAssertFalse(session.isImporting)
        XCTAssertFalse(session.hasPendingChanges)
        XCTAssertTrue(session.draft.pages.isEmpty)
        XCTAssertTrue(session.draft.additions.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    func testCancelledEditorImportDoesNotInterfereWithNextImport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        try PDFService.writeSample(to: source)
        let repository = LibraryRepository(rootURL: folder.appendingPathComponent("Library"))
        let session = MacEditorSession(notebookID: UUID(), draft: NotebookDraft(details: NotebookDetails(name: "Notes")))
        var errors: [String] = []
        let cancelled = try XCTUnwrap(session.importPDF(from: folder.appendingPathComponent("missing.pdf"), in: repository) { errors.append($0) })
        session.cancelImport()
        let current = try XCTUnwrap(session.importPDF(from: source, in: repository) { errors.append($0) })
        await cancelled.value
        await current.value
        XCTAssertEqual(session.draft.additions.count, 1)
        XCTAssertEqual(session.draft.pageCount, 3)
        XCTAssertFalse(session.isImporting)
        XCTAssertTrue(errors.isEmpty)
        await session.discard(in: repository)
    }

    func testNativeReaderKeepsStablePageWhenSavedRevisionChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("first.pdf")
        let nextURL = folder.appendingPathComponent("next.pdf")
        try PDFService.writeSample(to: firstURL)
        try PDFService.writeSample(to: nextURL)
        let notebook = Notebook(
            id: UUID(), name: "Notes", createdAt: Date(), modifiedAt: Date(), revisionID: nil,
            pages: (0..<3).map { _ in NotebookPage() }
        )
        let suite = "MacPlatformTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = ReadingPositionStore(defaults: defaults)
        positions.remember(pageID: notebook.pages[0].id, in: notebook.pages.map(\.id), for: notebook.id)
        let reader = MacPDFReader(
            url: firstURL, notebook: notebook, requestedPageID: nil,
            readingMode: .vertical, positions: positions, onPageChange: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let view = MacPDFReaderView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        coordinator.view = view
        coordinator.update(reader)
        let deadline = Date().addingTimeInterval(5)
        while coordinator.loading != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 0)
        var changed = notebook
        changed.pages.reverse()
        let replacement = MacPDFReader(
            url: nextURL, notebook: changed, requestedPageID: nil,
            readingMode: .horizontal, positions: positions, onPageChange: { _ in }
        )
        coordinator.update(replacement)
        coordinator.pageChanged()
        XCTAssertEqual(positions.pageID(for: notebook.id, in: notebook.pages.map(\.id)), notebook.pages[0].id)
        while coordinator.loading != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 2)
        XCTAssertEqual(view.pdfView.displayDirection, .horizontal)
        XCTAssertEqual(view.pdfView.displayMode, .singlePage)
        var request = MacPDFReader(
            url: nextURL, notebook: changed, requestedPageID: notebook.pages[1].id,
            readingMode: .horizontal, positions: positions, onPageChange: { _ in }, selectionRequestID: UUID()
        )
        coordinator.update(request)
        await Task.yield()
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 1)
        view.pdfView.go(to: try XCTUnwrap(view.pdfView.document?.page(at: 0)))
        coordinator.pageChanged()
        await Task.yield()
        request.selectionRequestID = UUID()
        coordinator.update(request)
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 1)
        request.selectionRequestID = UUID()
        coordinator.update(request)
        view.pdfView.go(to: try XCTUnwrap(view.pdfView.document?.page(at: 0)))
        coordinator.update(request)
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 0)
        coordinator.stop()
    }

    func testReaderCancellationCannotInstallCompletedLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.pdf")
        try PDFService.writeSample(to: source)
        let notebook = Notebook(
            id: UUID(), name: "Notes", createdAt: Date(), modifiedAt: Date(), revisionID: nil,
            pages: (0..<3).map { _ in NotebookPage() }
        )
        let suite = "MacPlatformTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = MacPDFReader(
            url: source, notebook: notebook, requestedPageID: nil,
            readingMode: .vertical, positions: ReadingPositionStore(defaults: defaults), onPageChange: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let view = MacPDFReaderView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        coordinator.view = view
        coordinator.update(reader)
        let loading = coordinator.loading
        coordinator.stop()
        await loading?.value
        XCTAssertNil(view.pdfView.document)
        XCTAssertNil(coordinator.view)
    }

    func testSavingPDFCopiesBytesAndKeepsDestinationWhenPreparationFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        let destination = folder.appendingPathComponent("saved.pdf")
        try PDFService.writeSample(to: source)
        try Data("old destination".utf8).write(to: destination)
        try await MacFileActions.copyPDF(source, to: destination)
        let saved = try Data(contentsOf: destination)
        XCTAssertEqual(saved, try Data(contentsOf: source))
        do {
            try await MacFileActions.copyPDF(folder.appendingPathComponent("missing.pdf"), to: destination)
            XCTFail("Expected missing source failure")
        } catch { }
        XCTAssertEqual(saved, try Data(contentsOf: destination))
    }

    func testSavedShareIsByteIdenticalAfterPageChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        await store.load()
        let original = try XCTUnwrap(store.activeNotebooks.first)
        try await store.rotatePages(in: original.id, ids: [try XCTUnwrap(original.pages.first?.id)])
        let saved = try XCTUnwrap(store.notebook(id: original.id))
        let source = try XCTUnwrap(store.pdfURL(for: saved))
        let share = try await store.shareCopy(of: saved.id)
        defer { ShareFileCleanup.remove(share) }
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: share))
    }
}
