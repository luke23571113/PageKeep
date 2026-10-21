import XCTest
import PDFKit
import UIKit
import Darwin
@testable import PageKeep

final class LargeNotebookTests: XCTestCase {
    func testHundredPageImportedNotebook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Library"))
        _ = try await repository.load()

        let fixtureURL = root.appendingPathComponent("source.pdf")
        let sampleURL = root.appendingPathComponent("sample.pdf")
        try PDFService.writeSample(to: sampleURL)
        let sample = try PDFService.validate(at: sampleURL)
        let fixture = PDFDocument()
        for index in 0..<100 {
            let page = try XCTUnwrap(sample.page(at: index % 3)?.copy() as? PDFPage)
            fixture.insert(page, at: fixture.pageCount)
        }
        try PDFService.write(fixture, to: fixtureURL)
        let started = Date()
        let prepared = try await repository.prepareImport(from: fixtureURL)
        let id = UUID()
        var snapshot = try await repository.create(id: id, name: "100 pages", from: prepared)
        await repository.discardPrepared(prepared)
        let notebook = try XCTUnwrap(snapshot.manifest.notebooks.first { $0.id == id })
        let reversed = notebook.pages.reversed().map(\.id)
        snapshot = try await repository.reorderPages(in: id, orderedIDs: reversed)
        snapshot = try await repository.rotatePages(in: id, ids: Set(reversed.prefix(10)))
        let result = try XCTUnwrap(snapshot.manifest.notebooks.first { $0.id == id })
        let pdfURL = try XCTUnwrap(repository.pdfURL(for: result))
        let saved = try PDFService.validate(at: pdfURL)
        XCTAssertEqual(saved.pageCount, 100)
        XCTAssertEqual(result.pages.map(\.id), reversed)
        XCTAssertTrue(saved.page(at: 99)?.string?.contains("Welcome") == true)
        let sharedURL = try await repository.shareCopy(of: id)
        defer { try? FileManager.default.removeItem(at: sharedURL.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: sharedURL), try Data(contentsOf: pdfURL))
        recordBenchmark("100-page PDF import/reorder/rotate/share", since: started, pdfURL: pdfURL, root: root)
    }

    func testThirtyImagePagesUseFileBackedStaging() async throws {
        let started = Date()
        let prepared = try await ScanProcessor().prepare(pageCount: 30) { index in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let size = CGSize(width: 1600, height: 2200)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.lightGray.setStroke()
                let lines = UIBezierPath()
                for y in stride(from: 250, through: 2050, by: 60) {
                    lines.move(to: CGPoint(x: 80, y: y))
                    lines.addLine(to: CGPoint(x: 1520, y: y))
                }
                lines.stroke()
                ("Synthetic scan page \(index + 1)\n\nx² + y² = z²" as NSString).draw(
                    in: CGRect(x: 100, y: 100, width: 1400, height: 500),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black]
                )
            }
        }
        defer { PDFService.discard(prepared) }
        let document = try PDFService.validate(at: prepared.url)
        XCTAssertEqual(document.pageCount, 30)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width / bounds.height, 1600.0 / 2200.0, accuracy: 0.001)
        let files = try FileManager.default.contentsOfDirectory(at: prepared.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["document.pdf"])
        recordBenchmark("30 synthetic 3.5MP scan pages", since: started, pdfURL: prepared.url, root: prepared.url.deletingLastPathComponent())
    }

    private func recordBenchmark(_ name: String, since started: Date, pdfURL: URL, root: URL) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let pdfBytes = (try? pdfURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var bytes = 0
        while let url = enumerator?.nextObject() as? URL {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let report = String(format: "%@: %.2fs; process peak RSS %.1f MB; saved PDF %.2f MB; fixture/store files %.2f MB", name, Date().timeIntervalSince(started), Double(usage.ru_maxrss) / 1_048_576, Double(pdfBytes) / 1_048_576, Double(bytes) / 1_048_576)
        print("PAGEKEEP_BENCHMARK \(report)")
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
