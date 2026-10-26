import XCTest
import UniformTypeIdentifiers
import UIKit
@testable import PageKeep

@MainActor
final class AcquisitionModelTests: XCTestCase {
    func testCanceledPreparationDiscardsLateResultWithoutCallingParent() async throws {
        let store = LibraryStore()
        let prepared = try makePrepared()
        let gate = PreparationGate()
        var completions = 0
        let model = AcquisitionModel(store: store, purpose: .draft, prepare: { _ in
            await gate.wait()
            return prepared
        }) { _ in completions += 1 }
        model.start(.importPDF)
        model.receiveImport(URL(fileURLWithPath: "/source.pdf"))
        await gate.waitUntilStarted()
        model.cancel()
        model.cancel()
        await gate.release()
        await waitUntil { !FileManager.default.fileExists(atPath: prepared.url.path) }
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(completions, 0)
        XCTAssertNil(model.prepared)
    }

    func testDraftTransferHappensOnceAndChildCancelDoesNotDeleteParentBatch() async throws {
        let prepared = try makePrepared()
        defer { PDFService.discard(prepared) }
        var received: [PreparedPDF] = []
        let model = AcquisitionModel(store: LibraryStore(), purpose: .draft, prepare: { _ in prepared }) { result in
            if case let .prepared(batch) = result { received.append(batch) }
        }
        model.start(.importPDF)
        let url = URL(fileURLWithPath: "/source.pdf")
        model.receiveImport(url)
        model.receiveImport(url)
        await waitUntil { model.phase == .finished }
        model.cancel()
        XCTAssertEqual(received.map(\.id), [prepared.id])
        XCTAssertNil(model.prepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
    }

    func testNewNotebookTransfersPreparedPagesToItsEditor() async throws {
        let prepared = try makePrepared()
        let model = AcquisitionModel(store: LibraryStore(), purpose: .createNotebook, prepare: { _ in prepared }) { _ in
            XCTFail("Creation should first open the editor")
        }
        model.start(.importPDF)
        model.receiveImport(URL(fileURLWithPath: "/source.pdf"))
        await waitUntil { model.phase == .editing }
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.editorDraft?.additions.map(\.id), [prepared.id])
        model.cancel()
        await waitUntil { !FileManager.default.fileExists(atPath: prepared.url.path) }
    }

    func testFailedPreparationRetriesTheSameInput() async throws {
        let prepared = try makePrepared()
        defer { PDFService.discard(prepared) }
        var attempts = 0
        var completions = 0
        let model = AcquisitionModel(store: LibraryStore(), purpose: .draft, prepare: { _ in
            attempts += 1
            if attempts == 1 { throw PDFError.invalidDocument }
            return prepared
        }) { _ in completions += 1 }
        model.start(.importPDF)
        model.receiveImport(URL(fileURLWithPath: "/source.pdf"))
        await waitUntil { model.phase == .failed }
        XCTAssertTrue(model.hasPendingPages)
        model.retry()
        await waitUntil { model.phase == .finished }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(completions, 1)
    }

    func testRepeatedAppendSavesOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: root.appendingPathComponent("Library")))
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        let prepared = try makePrepared()
        var completions = 0
        let model = AcquisitionModel(store: store, purpose: .append(notebook.id), prepare: { _ in prepared }) { _ in
            completions += 1
        }
        model.start(.importPDF)
        model.receiveImport(URL(fileURLWithPath: "/source.pdf"))
        await waitUntil { model.phase == .ready }
        model.save()
        model.save()
        model.cancel()
        await waitUntil { model.phase == .finished }
        XCTAssertEqual(store.notebook(id: notebook.id)?.pageCount, 6)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
    }

    func testPickerCompletionAndTeardownIgnoreLaterDelegateCallbacks() {
        var imports = 0
        var cancellations = 0
        let importer = PDFImporter(onImport: { _ in imports += 1 }, onCancel: { cancellations += 1 })
        let coordinator = importer.makeCoordinator()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
        coordinator.documentPicker(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/source.pdf")])
        coordinator.documentPickerWasCancelled(picker)
        coordinator.documentPicker(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/another.pdf")])
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(cancellations, 0)
        PDFImporter.dismantleUIViewController(picker, coordinator: coordinator)
        XCTAssertNil(picker.delegate)
        XCTAssertFalse(coordinator.isActive)
    }

    private func makePrepared() throws -> PreparedPDF {
        let url = try PDFService.makeStagingURL()
        try PDFService.writeSample(to: url)
        return PreparedPDF(url: url, suggestedName: "Incoming", pageCount: 3)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
