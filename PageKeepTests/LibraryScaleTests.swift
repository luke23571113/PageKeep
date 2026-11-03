import XCTest
import PDFKit
import Darwin
@testable import PageKeep

final class LibraryScaleTests: XCTestCase {
    func testThousandPageNotebookEditsAndExactExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Library"))
        _ = try await repository.load()
        let source = try fixture(pageCount: 1_000, root: root)
        let started = Date()
        let prepared = try await repository.prepareImport(from: source)
        defer { PDFService.discard(prepared) }
        let id = UUID()
        let created = try await repository.create(id: id, details: .init(name: "1,000 pages"), from: [prepared])
        let original = try XCTUnwrap(created.manifest.notebooks.first { $0.id == id })
        let order = original.pages.reversed().map(\.id)
        _ = try await repository.reorderPages(in: id, orderedIDs: order)
        _ = try await repository.rotatePages(in: id, ids: [order[0]])
        let loaded = try await LibraryRepository(rootURL: repository.rootURL).load()
        let notebook = try XCTUnwrap(loaded.manifest.notebooks.first { $0.id == id })
        XCTAssertEqual(notebook.pages.map(\.id), order)
        XCTAssertTrue(loaded.notebookErrors.isEmpty)
        let savedURL = try XCTUnwrap(repository.pdfURL(for: notebook))
        let shared = try await repository.shareCopy(of: id)
        defer { ShareFileCleanup.remove(shared) }
        XCTAssertEqual(try Data(contentsOf: savedURL), try Data(contentsOf: shared))
        report("1,000-page import/reorder/rotate/reload/share", since: started, root: root)
    }

    func testGrowingLibraryThroughFiveThousandPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Library"))
        let initial = try await repository.load()
        _ = try await repository.deleteNotebook(initial.manifest.notebooks[0].id)
        let source = try fixture(pageCount: 100, root: root)
        let prepared = try await repository.prepareImport(from: source)
        defer { PDFService.discard(prepared) }
        let folderIDs = (0..<5).map { _ in UUID() }
        for (index, id) in folderIDs.enumerated() {
            _ = try await repository.createFolder(id: id, name: "Semester \(index)")
        }
        let started = Date()
        for index in 0..<50 {
            let id = UUID()
            _ = try await repository.create(
                id: id, details: .init(name: "Course \(index)", folderID: folderIDs[index % folderIDs.count]), from: [prepared]
            )
            if index.isMultiple(of: 5) { _ = try await repository.setArchived(true, ids: [id]) }
            if index == 9 { report("Distributed 1,000 pages", since: started, root: root) }
        }
        let loaded = try await LibraryRepository(rootURL: repository.rootURL).load()
        XCTAssertEqual(loaded.manifest.notebooks.reduce(0) { $0 + $1.pageCount }, 5_000)
        XCTAssertEqual(loaded.manifest.notebooks.filter(\.isArchived).count, 10)
        XCTAssertEqual(loaded.manifest.folders.count, 5)
        XCTAssertTrue(loaded.manifest.notebooks.allSatisfy { $0.folderID != nil })
        XCTAssertEqual(Set(loaded.manifest.itemOrder).count, 55)
        XCTAssertTrue(loaded.notebookErrors.isEmpty)
        XCTAssertEqual(NotebookSearch.results(in: loaded.manifest.notebooks, query: "Course 49").first?.name, "Course 49")
        report("Distributed 5,000 pages including archives", since: started, root: root)
    }

    private func fixture(pageCount: Int, root: URL) throws -> URL {
        let sampleURL = root.appendingPathComponent("sample.pdf")
        try PDFService.writeSample(to: sampleURL)
        let sample = try PDFService.validate(at: sampleURL)
        let document = PDFDocument()
        for index in 0..<pageCount {
            let page = try XCTUnwrap(sample.page(at: index % sample.pageCount)?.copy() as? PDFPage)
            document.insert(page, at: document.pageCount)
        }
        let url = root.appendingPathComponent("fixture.pdf")
        try PDFService.write(document, to: url)
        return url
    }

    private func report(_ label: String, since started: Date, root: URL) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var bytes = 0
        while let url = files?.nextObject() as? URL {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let text = "\(label): \(Date().timeIntervalSince(started)) seconds; peak process RSS \(usage.ru_maxrss) bytes; fixture/store \(bytes) bytes. Synthetic text PDFs, not camera quality."
        print("PAGEKEEP_BENCHMARK \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
