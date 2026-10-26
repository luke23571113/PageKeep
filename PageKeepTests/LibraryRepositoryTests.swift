import XCTest
import PDFKit
import CoreGraphics
import CoreText
import UIKit
@testable import PageKeep

@MainActor
final class LibraryRepositoryTests: XCTestCase {
    private var folder: URL!
    private var root: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PageKeepTests-\(UUID().uuidString)")
        root = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFirstLaunchHasThreeRealPagesAndStableIDs() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let sample = try XCTUnwrap(first.manifest.notebooks.first)
        XCTAssertEqual(first.manifest.notebooks.count, 1)
        XCTAssertEqual(sample.pageCount, 3)
        let document = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: sample)))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.string?.contains("Welcome to PageKeep") == true)
        let second = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(second.manifest.notebooks, first.manifest.notebooks)
        XCTAssertTrue(second.notebookErrors.isEmpty)
    }

    func testDeletingSampleDoesNotReseed() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let id = try XCTUnwrap(first.manifest.notebooks.first?.id)
        _ = try await repository.deleteNotebook(id)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertTrue(reloaded.manifest.initialized)
        XCTAssertTrue(reloaded.manifest.notebooks.isEmpty)
    }

    func testInterruptedFirstLaunchDoesNotInstallPartialLibrary() async throws {
        let repository = LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeInitialInstall = checkpoint { throw TestFailure.injected }
        }
        do { _ = try await repository.load(); XCTFail("Expected injected failure") }
        catch TestFailure.injected { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let snapshot = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(snapshot.manifest.notebooks.first?.pageCount, 3)
        let remaining = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.map(\.lastPathComponent), ["Library"])
    }

    func testFailuresLeaveCurrentManifestAndSavedPDFUnchanged() async throws {
        let first = try await LibraryRepository(rootURL: root).load()
        let sample = try XCTUnwrap(first.manifest.notebooks.first)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let source = try makeFixture()
        for checkpoint in [LibraryRepository.Checkpoint.afterCandidatePDF, .beforeBackup, .afterBackup, .beforeManifestCommit] {
            let repository = LibraryRepository(rootURL: root) { reached in
                if String(describing: reached) == String(describing: checkpoint) { throw TestFailure.injected }
            }
            let prepared = try await repository.prepareImport(from: source)
            do { _ = try await repository.append(to: sample.id, from: prepared); XCTFail("Expected injected failure") }
            catch TestFailure.injected { }
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path), "The caller owns cancellation of prepared imports")
            let reloaded = try await LibraryRepository(rootURL: root).load()
            XCTAssertEqual(reloaded.manifest.notebooks, first.manifest.notebooks)
            XCTAssertTrue(reloaded.notebookErrors.isEmpty)
            await repository.discardPrepared(prepared)
        }
    }

    func testCleanupRetainsBothCommittedRevisionsUntilNextValidatedLoad() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let original = try XCTUnwrap(first.manifest.notebooks.first)
        let page = try XCTUnwrap(original.pages.first?.id)
        let second = try await repository.rotatePages(in: original.id, ids: [page])
        let newer = try XCTUnwrap(second.manifest.notebooks.first)
        _ = try await repository.rotatePages(in: original.id, ids: [page])
        let originalURL = try XCTUnwrap(repository.pdfURL(for: original))
        let backupURL = try XCTUnwrap(repository.pdfURL(for: newer))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        _ = try await repository.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testDamagedCurrentRequiresExplicitRecovery() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let sample = try XCTUnwrap(first.manifest.notebooks.first)
        var details = sample.details
        details.name = "Changed"
        _ = try await repository.edit(sample.id, details: details, appending: [])
        let damaged = Data("broken JSON".utf8)
        try damaged.write(to: root.appendingPathComponent("manifest.json"))
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); XCTFail("Expected damaged manifest") }
        catch LibraryError.damagedManifest { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), damaged)
        let canRecover = await reopened.canRecover()
        XCTAssertTrue(canRecover)
        let recovered = try await reopened.recover()
        XCTAssertEqual(recovered.manifest.notebooks, first.manifest.notebooks)
        XCTAssertTrue(recovered.notebookErrors.isEmpty)
    }

    func testMissingPDFIsReportedWithoutReseedingOrRewritingManifest() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let sample = try XCTUnwrap(first.manifest.notebooks.first)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: XCTUnwrap(repository.pdfURL(for: sample)))
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks, first.manifest.notebooks)
        XCTAssertNotNil(reloaded.notebookErrors[sample.id])
        XCTAssertEqual(try Data(contentsOf: manifestURL), bytes)
        do { _ = try await repository.rotatePages(in: sample.id, ids: [sample.pages[0].id]); XCTFail("Expected missing PDF") }
        catch LibraryError.missingPDF { }
    }

    func testInvalidManifestsDoNotDeleteUnreferencedFiles() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let orphan = root.appendingPathComponent("PDFs/orphan.pdf")
        try Data("keep me".utf8).write(to: orphan)
        try Data("broken".utf8).write(to: root.appendingPathComponent("manifest.backup.json"))
        _ = try await repository.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        try Data("broken".utf8).write(to: root.appendingPathComponent("manifest.json"))
        do { _ = try await repository.load(); XCTFail("Expected damaged manifest") }
        catch LibraryError.damagedManifest { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testFutureSchemaCannotRecoverOrWrite() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let future = Data("{\"schemaVersion\":99,\"futureData\":true}".utf8)
        let url = root.appendingPathComponent("manifest.json")
        try future.write(to: url)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); XCTFail("Expected newer schema") }
        catch LibraryError.newerSchema { }
        let canRecover = await reopened.canRecover()
        XCTAssertFalse(canRecover)
        do {
            _ = try await reopened.edit(UUID(), details: NotebookDetails(name: "No write"), appending: [])
            XCTFail("Expected newer schema")
        }
        catch LibraryError.newerSchema { }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testNativePageEditsPreserveTextBoundsAnnotationsAndIDs() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let prepared = try await repository.prepareImport(from: makeFixture())
        let imported = try PDFService.validate(at: prepared.url)
        let annotationBounds = try XCTUnwrap(imported.page(at: 0)?.annotations.first(where: {
            $0.contents == "A preserved note"
        })?.bounds)
        let id = UUID()
        let created = try await repository.create(id: id, details: NotebookDetails(name: "Fixture"), from: [prepared])
        let notebook = try XCTUnwrap(created.manifest.notebooks.first(where: { $0.id == id }))
        XCTAssertEqual(try Data(contentsOf: prepared.url), try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: notebook))),
                       "Initial import preserves the original PDF bytes")
        let originalIDs = notebook.pages.map(\.id)
        let rotated = try await repository.rotatePages(in: id, ids: [originalIDs[0]])
        let afterRotation = try XCTUnwrap(rotated.manifest.notebooks.first(where: { $0.id == id }))
        let document = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: afterRotation)))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(page.pageRef?.rotationAngle, 90, "PDF /Rotate specifies clockwise display rotation")
        XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 400, height: 600))
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 10, y: 20, width: 360, height: 540))
        XCTAssertTrue(page.string?.contains("First vector page") == true)
        XCTAssertEqual(page.annotations.first(where: { $0.contents == "A preserved note" })?.bounds,
                       annotationBounds)
        var resources: CGPDFDictionaryRef?
        var images: CGPDFDictionaryRef?
        if let reference = page.pageRef, let dictionary = reference.dictionary,
           CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
           let resources,
           CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images {
            XCTAssertEqual(CGPDFDictionaryGetCount(images), 0, "Vector pages must not become page-sized raster images")
        }
        XCTAssertEqual(afterRotation.pages.map(\.id), originalIDs)
        let reordered = try await repository.reorderPages(in: id, orderedIDs: originalIDs.reversed())
        let afterReorder = try XCTUnwrap(reordered.manifest.notebooks.first(where: { $0.id == id }))
        let saved = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: afterReorder)))
        XCTAssertTrue(saved.page(at: 0)?.string?.contains("Second vector page") == true)
        XCTAssertTrue(saved.page(at: 1)?.string?.contains("First vector page") == true)
        XCTAssertEqual(saved.page(at: 1)?.annotations.first?.contents, "A preserved note")
        XCTAssertEqual(afterReorder.pages.map(\.id), Array(originalIDs.reversed()))
        await repository.discardPrepared(prepared)
    }

    func testSingleRotationDisplaysTopLeftMarkAtTopRight() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let prepared = try await repository.prepareImport(from: makeOrientationFixture())
        let id = UUID()
        let created = try await repository.create(id: id, details: NotebookDetails(name: "Orientation"), from: [prepared])
        let original = try XCTUnwrap(created.manifest.notebooks.first(where: { $0.id == id }))
        let rotated = try await repository.rotatePages(in: id, ids: [original.pages[0].id])
        let notebook = try XCTUnwrap(rotated.manifest.notebooks.first(where: { $0.id == id }))
        let document = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: notebook)))
        let image = try XCTUnwrap(document.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 300), for: .mediaBox).cgImage)
        let topLeft = try pixel(in: image, xFraction: 0.1, yFraction: 0.1)
        let topRight = try pixel(in: image, xFraction: 0.9, yFraction: 0.1)
        XCTAssertTrue(topRight.red > 200 && topRight.green < 80, "The red top-left mark should turn to the top-right")
        XCTAssertTrue(topLeft.green > 180, "The former top-left should become white")
        await repository.discardPrepared(prepared)
    }

    func testAppendDeleteLastPageAndByteExactShare() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = try XCTUnwrap(initial.manifest.notebooks.first)
        let originalIDs = sample.pages.map(\.id)
        let prepared = try await repository.prepareImport(from: makeFixture())
        let appended = try await repository.append(to: sample.id, from: prepared)
        let notebook = try XCTUnwrap(appended.manifest.notebooks.first)
        XCTAssertEqual(notebook.pageCount, 5)
        XCTAssertEqual(Array(notebook.pages.prefix(3)).map(\.id), originalIDs)
        let savedURL = try XCTUnwrap(repository.pdfURL(for: notebook))
        let sharedURL = try await repository.shareCopy(of: notebook.id)
        defer { try? FileManager.default.removeItem(at: sharedURL.deletingLastPathComponent()) }
        XCTAssertNotEqual(savedURL, sharedURL)
        XCTAssertEqual(try Data(contentsOf: savedURL), try Data(contentsOf: sharedURL))
        let deleted = try await repository.deletePages(in: notebook.id, ids: Set(notebook.pages.map(\.id)))
        let empty = try XCTUnwrap(deleted.manifest.notebooks.first)
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertNil(empty.revisionID)
        XCTAssertNil(repository.pdfURL(for: empty))
        do { _ = try await repository.shareCopy(of: empty.id); XCTFail("Expected empty notebook") }
        catch LibraryError.emptyNotebook { }
        let repopulated = try await repository.append(to: empty.id, from: prepared)
        XCTAssertEqual(repopulated.manifest.notebooks.first?.pageCount, 2)
        await repository.discardPrepared(prepared)
    }

    func testInvalidAndEncryptedImportsAreRejected() async throws {
        let repository = LibraryRepository(rootURL: root)
        let invalid = folder.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        do { _ = try await repository.prepareImport(from: invalid); XCTFail("Expected invalid PDF") }
        catch PDFError.invalidDocument { }
        let source = try makeFixture()
        let document = try XCTUnwrap(PDFDocument(url: source))
        let encrypted = folder.appendingPathComponent("encrypted.pdf")
        XCTAssertTrue(document.write(to: encrypted, withOptions: [
            .ownerPasswordOption: "owner-secret", .userPasswordOption: "reader-secret"
        ]))
        do { _ = try await repository.prepareImport(from: encrypted); XCTFail("Expected encrypted PDF") }
        catch PDFError.encryptedDocument { }
        let empty = PDFDocument()
        do { try PDFService.write(empty, to: folder.appendingPathComponent("empty.pdf")); XCTFail("Expected zero-page rejection") }
        catch PDFError.emptyDocument { }
    }

    func testCancellationBeforeCommitKeepsManifest() async throws {
        let repository = LibraryRepository(rootURL: root)
        let first = try await repository.load()
        let sample = try XCTUnwrap(first.manifest.notebooks.first)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var details = sample.details
            details.name = "Cancelled"
            return try await repository.edit(sample.id, details: details, appending: [])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
    }

    func testFourRotationsReturnToAnImportedPagesOriginalRotation() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let source = try makeFixture()
        let imported = try PDFService.validate(at: source)
        imported.page(at: 0)?.rotation = 270
        try PDFService.write(imported, to: source)
        let prepared = try await repository.prepareImport(from: source)
        let id = UUID()
        let created = try await repository.create(id: id, details: NotebookDetails(name: "Already rotated"), from: [prepared])
        let original = try XCTUnwrap(created.manifest.notebooks.first(where: { $0.id == id }))
        var snapshot = created
        for expectedRotation in [0, 90, 180, 270] {
            snapshot = try await repository.rotatePages(in: id, ids: [original.pages[0].id])
            let notebook = try XCTUnwrap(snapshot.manifest.notebooks.first(where: { $0.id == id }))
            let document = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: notebook)))
            XCTAssertEqual(document.page(at: 0)?.rotation, expectedRotation)
            XCTAssertEqual(document.page(at: 1)?.rotation, 0)
            XCTAssertEqual(notebook.pages, original.pages)
        }
        await repository.discardPrepared(prepared)
    }

    func testRenamePersistsWithoutChangingSavedPDF() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let original = try XCTUnwrap(initial.manifest.notebooks.first)
        let originalBytes = try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: original)))
        var details = original.details
        details.name = "  Class notes  "
        _ = try await repository.edit(original.id, details: details, appending: [])
        let reloaded = try await LibraryRepository(rootURL: root).load()
        let renamed = try XCTUnwrap(reloaded.manifest.notebooks.first)
        XCTAssertEqual(renamed.name, "Class notes")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        XCTAssertEqual(renamed.pages, original.pages)
        XCTAssertEqual(renamed.revisionID, original.revisionID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: renamed))), originalBytes)
    }

    func testOutOfSpaceBeforeCommitKeepsPriorPDFBytes() async throws {
        let initialRepository = LibraryRepository(rootURL: root)
        let initial = try await initialRepository.load()
        let original = try XCTUnwrap(initial.manifest.notebooks.first)
        let originalURL = try XCTUnwrap(initialRepository.pdfURL(for: original))
        let originalBytes = try Data(contentsOf: originalURL)
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let repository = LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeManifestCommit = checkpoint { throw POSIXError(.ENOSPC) }
        }
        do {
            _ = try await repository.rotatePages(in: original.id, ids: [original.pages[0].id])
            XCTFail("Expected simulated disk-full failure")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOSPC)
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), manifestBytes)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks, initial.manifest.notebooks)
    }

    func testZeroPageAndUnavailableSourceImportsFail() async throws {
        let repository = LibraryRepository(rootURL: root)
        let emptyURL = folder.appendingPathComponent("zero-pages.pdf")
        var data = Data("%PDF-1.4\n".utf8)
        let catalogOffset = data.count
        data.append(Data("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8))
        let pagesOffset = data.count
        data.append(Data("2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n".utf8))
        let xrefOffset = data.count
        data.append(Data("xref\n0 3\n0000000000 65535 f \n".utf8))
        data.append(Data(String(format: "%010d 00000 n \n", catalogOffset).utf8))
        data.append(Data(String(format: "%010d 00000 n \n", pagesOffset).utf8))
        data.append(Data("trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try data.write(to: emptyURL)
        do { _ = try await repository.prepareImport(from: emptyURL); XCTFail("Expected zero-page rejection") }
        catch PDFError.emptyDocument { }
        catch PDFError.invalidDocument { }
        let unavailable = folder.appendingPathComponent("unavailable.pdf")
        do { _ = try await repository.prepareImport(from: unavailable); XCTFail("Expected unavailable source failure") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Import preparation must not initialize the library")
    }

    func testV1MigrationPreservesNamesIDsPDFsAndOldVisibleOrderWithoutWriting() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        var original = try XCTUnwrap(initial.manifest.notebooks.first)
        original.modifiedAt = Date(timeIntervalSince1970: 100)
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let date = Date(timeIntervalSince1970: 200)
        let earlier = Notebook(id: earlierID, name: "Duplicate", createdAt: date, modifiedAt: date, revisionID: nil, pages: [])
        let later = Notebook(id: laterID, name: "Duplicate", createdAt: date, modifiedAt: date, revisionID: nil, pages: [])
        let bytes = try legacyManifest([original, later, earlier])
        let currentURL = root.appendingPathComponent("manifest.json")
        try bytes.write(to: currentURL)
        let migrated = try await repository.load()
        XCTAssertEqual(migrated.manifest.schemaVersion, 2)
        XCTAssertEqual(migrated.manifest.notebooks.map(\.id), [earlierID, laterID, original.id])
        XCTAssertEqual(migrated.manifest.notebooks.map(\.name), ["Duplicate", "Duplicate", original.name])
        XCTAssertTrue(migrated.manifest.notebooks.allSatisfy { $0.symbolName == "book.closed" && $0.colorID == "default" && !$0.isArchived })
        XCTAssertEqual(migrated.manifest.notebooks.last, original)
        XCTAssertTrue(migrated.notebookErrors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: currentURL), bytes)
        _ = try await repository.setArchived(true, ids: [earlierID])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.backup.json")), bytes)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertTrue(reloaded.manifest.notebooks[0].isArchived)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as? [String: Any]
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, 2)
    }

    func testV1BackupRecoveryKeepsRawBackupAndMigratesOnNextMutation() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let bytes = try legacyManifest(initial.manifest.notebooks)
        let backupURL = root.appendingPathComponent("manifest.backup.json")
        let currentURL = root.appendingPathComponent("manifest.json")
        try bytes.write(to: backupURL)
        try Data("damaged".utf8).write(to: currentURL)
        let recovered = try await repository.recover()
        XCTAssertEqual(recovered.manifest.notebooks, initial.manifest.notebooks)
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
        XCTAssertEqual(try Data(contentsOf: currentURL), bytes)
        var details = initial.manifest.notebooks[0].details
        details.name = "Recovered"
        _ = try await repository.edit(initial.manifest.notebooks[0].id, details: details, appending: [])
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks[0].name, "Recovered")
    }

    func testV1MissingPDFKeepsManifestAndReportsError() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let original = initial.manifest.notebooks[0]
        let bytes = try legacyManifest([original])
        let url = root.appendingPathComponent("manifest.json")
        try bytes.write(to: url)
        try FileManager.default.removeItem(at: XCTUnwrap(repository.pdfURL(for: original)))
        let migrated = try await repository.load()
        XCTAssertNotNil(migrated.notebookErrors[original.id])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testV2RequiresAppearanceAndArchiveFieldsAndProtectsFutureBackup() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let url = root.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: url)
        for field in ["symbolName", "colorID", "isArchived"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var notebooks = try XCTUnwrap(json["notebooks"] as? [[String: Any]])
            notebooks[0].removeValue(forKey: field)
            json["notebooks"] = notebooks
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            do { _ = try await repository.load(); XCTFail("Missing V2 field should fail: \(field)") }
            catch LibraryError.damagedManifest { }
        }
        try bytes.write(to: url)
        try Data("{\"schemaVersion\":99}".utf8).write(to: root.appendingPathComponent("manifest.backup.json"))
        do { _ = try await repository.load(); XCTFail("Expected newer backup schema rejection") }
        catch LibraryError.newerSchema { }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testOrderArchiveAndMetadataPersistWithoutRewritingPDF() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        let originalBytes = try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: sample)))
        let prepared = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(prepared) }
        let firstID = UUID()
        let secondID = UUID()
        _ = try await repository.create(id: firstID, details: NotebookDetails(name: "First"), from: [prepared])
        _ = try await repository.create(id: secondID, details: NotebookDetails(name: "Second"), from: [prepared])
        _ = try await repository.setArchived(true, ids: [firstID])
        let reordered = try await repository.reorderNotebooks(orderedActiveIDs: [sample.id, secondID])
        XCTAssertEqual(reordered.manifest.notebooks.map(\.id), [sample.id, firstID, secondID])
        _ = try await repository.edit(sample.id, details: NotebookDetails(name: "Notes", symbolName: "pencil", colorID: "blue"), appending: [])
        _ = try await repository.setArchived(false, ids: [firstID])
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks.map(\.id), [sample.id, firstID, secondID])
        let edited = reloaded.manifest.notebooks[0]
        XCTAssertEqual(edited.symbolName, "pencil")
        XCTAssertEqual(edited.colorID, "blue")
        XCTAssertEqual(edited.revisionID, sample.revisionID)
        XCTAssertEqual(edited.pages, sample.pages)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: edited))), originalBytes)
    }

    func testMetadataFailuresAndInvalidOrdersKeepSavedLibrary() async throws {
        let initialRepository = LibraryRepository(rootURL: root)
        let initial = try await initialRepository.load()
        let sample = initial.manifest.notebooks[0]
        let repository = LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeManifestCommit = checkpoint { throw TestFailure.injected }
        }
        do { _ = try await repository.setArchived(true, ids: [sample.id]); XCTFail("Expected failure") }
        catch TestFailure.injected { }
        do { _ = try await repository.edit(sample.id, details: NotebookDetails(name: "Changed", colorID: "red"), appending: []); XCTFail("Expected failure") }
        catch TestFailure.injected { }
        for order in [[], [sample.id, sample.id], [UUID()]] {
            do { _ = try await repository.reorderNotebooks(orderedActiveIDs: order); XCTFail("Expected invalid order") }
            catch LibraryError.invalidChange { }
        }
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks, initial.manifest.notebooks)
    }

    func testSerializedCreateAndEditResolveNamesIncludingArchive() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let prepared = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(prepared) }
        let ids = [UUID(), UUID(), UUID()]
        _ = try await repository.create(id: ids[0], details: NotebookDetails(name: "  Math  "), from: [prepared])
        _ = try await repository.setArchived(true, ids: [ids[0]])
        _ = try await repository.create(id: ids[1], details: NotebookDetails(name: "math"), from: [prepared])
        let created = try await repository.create(id: ids[2], details: NotebookDetails(name: "Math (1)"), from: [prepared])
        XCTAssertEqual(created.manifest.notebooks.first?.name, "Math (2)")
        let edited = try await repository.edit(ids[1], details: NotebookDetails(name: "Math"), appending: [])
        XCTAssertEqual(edited.manifest.notebooks.first(where: { $0.id == ids[1] })?.name, "Math (1)")
        do { _ = try await repository.edit(ids[1], details: NotebookDetails(name: " \n "), appending: []); XCTFail("Expected empty name") }
        catch LibraryError.emptyName { }
    }

    func testMultiSourceCreateAndEditKeepSourceOrderAndStableExistingIDs() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let first = try await repository.prepareImport(from: makeFixture())
        let second = try await repository.prepareImport(from: makeOrientationFixture())
        defer { PDFService.discard(first); PDFService.discard(second) }
        let id = UUID()
        let created = try await repository.create(id: id, details: NotebookDetails(name: "Combined"), from: [second, first])
        let original = try XCTUnwrap(created.manifest.notebooks.first)
        XCTAssertEqual(original.pageCount, 3)
        let createdPDF = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: original)))
        XCTAssertEqual(createdPDF.page(at: 0)?.bounds(for: .mediaBox).width, 200)
        XCTAssertTrue(createdPDF.page(at: 1)?.string?.contains("First vector page") == true)
        XCTAssertTrue(createdPDF.page(at: 2)?.string?.contains("Second vector page") == true)
        let edited = try await repository.edit(id, details: NotebookDetails(name: "Edited", colorID: "red"), appending: [first, second])
        let saved = try XCTUnwrap(edited.manifest.notebooks.first)
        XCTAssertEqual(saved.pageCount, 6)
        XCTAssertEqual(Array(saved.pages.prefix(3)), original.pages)
        XCTAssertEqual(Set(saved.pages.map(\.id)).count, 6)
        XCTAssertEqual(saved.name, "Edited")
        XCTAssertEqual(saved.colorID, "red")
        let savedPDF = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: saved)))
        XCTAssertTrue(savedPDF.page(at: 3)?.string?.contains("First vector page") == true)
        XCTAssertEqual(savedPDF.page(at: 5)?.bounds(for: .mediaBox).width, 200)
    }

    func testBatchCountMismatchDoesNotPartiallySaveMetadataOrPages() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        let good = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(good) }
        let bad = PreparedPDF(url: good.url, suggestedName: "Mismatch", pageCount: good.pageCount + 1)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        do { _ = try await repository.edit(sample.id, details: NotebookDetails(name: "Changed"), appending: [good, bad]); XCTFail("Expected mismatch") }
        catch LibraryError.pageCountMismatch { }
        do { _ = try await repository.create(id: UUID(), details: NotebookDetails(name: "Changed"), from: [good, bad]); XCTFail("Expected mismatch") }
        catch LibraryError.pageCountMismatch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
        let snapshot = try await repository.load()
        XCTAssertEqual(snapshot.manifest.notebooks, initial.manifest.notebooks)
    }

    func testMultiSourceFailuresAreAtomicAndStagedInputsCanRetry() async throws {
        let initialRepository = LibraryRepository(rootURL: root)
        let initial = try await initialRepository.load()
        let original = initial.manifest.notebooks[0]
        let first = try await initialRepository.prepareImport(from: makeFixture())
        let second = try await initialRepository.prepareImport(from: makeOrientationFixture())
        defer { PDFService.discard(first); PDFService.discard(second) }
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        for creating in [true, false] {
            for checkpoint in [LibraryRepository.Checkpoint.afterCandidatePDF, .beforeBackup, .afterBackup, .beforeManifestCommit] {
                let repository = LibraryRepository(rootURL: root) { reached in
                    if String(describing: reached) == String(describing: checkpoint) { throw TestFailure.injected }
                }
                do {
                    if creating {
                        _ = try await repository.create(id: UUID(), details: NotebookDetails(name: "Combined"), from: [first, second])
                    } else {
                        _ = try await repository.edit(original.id, details: NotebookDetails(name: "Changed", colorID: "red"), appending: [first, second])
                    }
                    XCTFail("Expected injected failure")
                } catch TestFailure.injected { }
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
                XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
                let snapshot = try await LibraryRepository(rootURL: root).load()
                XCTAssertEqual(snapshot.manifest.notebooks, initial.manifest.notebooks)
                XCTAssertTrue(snapshot.notebookErrors.isEmpty)
            }
        }
        let retried = try await initialRepository.edit(original.id, details: NotebookDetails(name: "Changed"), appending: [first, second])
        XCTAssertEqual(retried.manifest.notebooks[0].pageCount, 6)
    }

    func testStoreSaveReportsFirstAddedPageAndKeepsFullManualOrder() async throws {
        let store = LibraryStore(repository: LibraryRepository(rootURL: root))
        await store.load()
        let sample = try XCTUnwrap(store.activeNotebooks.first)
        let prepared = try await store.repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(prepared) }
        let saved = try await store.saveNotebook(details: NotebookDetails(name: "New"), notebookID: nil, additions: [prepared])
        let original = try XCTUnwrap(store.notebook(id: saved.notebookID))
        XCTAssertEqual(saved.firstAddedPageID, original.pages.first?.id)
        let appended = try await store.saveNotebook(details: original.details, notebookID: original.id, additions: [prepared])
        XCTAssertEqual(appended.firstAddedPageID, store.notebook(id: original.id)?.pages[2].id)
        try await store.setArchived(true, ids: [original.id])
        XCTAssertEqual(store.activeNotebooks.map(\.id), [sample.id])
        XCTAssertEqual(store.archivedNotebooks.map(\.id), [original.id])
        XCTAssertEqual(store.notebooks.map(\.id), [original.id, sample.id])
        let metadata = try await store.saveNotebook(details: NotebookDetails(name: "Renamed"), notebookID: sample.id, additions: [])
        XCTAssertNil(metadata.firstAddedPageID)
        XCTAssertEqual(store.notebooks.map(\.id), [original.id, sample.id])
    }

    func testInterruptedV1MigrationKeepsLegacyCurrentAndCanRetry() async throws {
        let initialRepository = LibraryRepository(rootURL: root)
        let initial = try await initialRepository.load()
        let sample = initial.manifest.notebooks[0]
        let legacy = try legacyManifest(initial.manifest.notebooks)
        let currentURL = root.appendingPathComponent("manifest.json")
        try legacy.write(to: currentURL)
        for checkpoint in [LibraryRepository.Checkpoint.beforeBackup, .afterBackup, .beforeManifestCommit] {
            let repository = LibraryRepository(rootURL: root) { reached in
                if String(describing: reached) == String(describing: checkpoint) { throw TestFailure.injected }
            }
            do { _ = try await repository.setArchived(true, ids: [sample.id]); XCTFail("Expected injected failure") }
            catch TestFailure.injected { }
            XCTAssertEqual(try Data(contentsOf: currentURL), legacy)
            let reloaded = try await LibraryRepository(rootURL: root).load()
            XCTAssertEqual(reloaded.manifest.notebooks, initial.manifest.notebooks)
        }
        let retried = try await initialRepository.setArchived(true, ids: [sample.id])
        XCTAssertTrue(retried.manifest.notebooks[0].isArchived)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.backup.json")), legacy)
    }

    func testFailedReorderDoesNotPublishAnUnsavedOrder() async throws {
        let repository = LibraryRepository(rootURL: root)
        let store = LibraryStore(repository: repository)
        await store.load()
        let sample = try XCTUnwrap(store.notebooks.first)
        let prepared = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(prepared) }
        let saved = try await store.saveNotebook(details: NotebookDetails(name: "New"), notebookID: nil, additions: [prepared])
        let expected = store.notebooks
        let failingStore = LibraryStore(repository: LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeManifestCommit = checkpoint { throw TestFailure.injected }
        })
        await failingStore.load()
        do { try await failingStore.reorderNotebooks(orderedActiveIDs: [sample.id, saved.notebookID]); XCTFail("Expected failure") }
        catch TestFailure.injected { }
        XCTAssertEqual(failingStore.notebooks, expected)
        XCTAssertFalse(failingStore.isBusy)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.manifest.notebooks, expected)
    }

    func testArchivedPDFSurvivesCleanupAndNewNotebookNeedsPages() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        _ = try await repository.setArchived(true, ids: [sample.id])
        _ = try await repository.edit(sample.id, details: NotebookDetails(name: "Archived"), appending: [])
        let snapshot = try await repository.load()
        XCTAssertTrue(snapshot.manifest.notebooks[0].isArchived)
        XCTAssertTrue(snapshot.notebookErrors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(repository.pdfURL(for: sample)).path))
        do { _ = try await repository.create(id: UUID(), details: NotebookDetails(name: "Empty"), from: []); XCTFail("Expected pages") }
        catch PDFError.emptyDocument { }
    }

    func testArrangedMixedPagesSaveMetadataContentAndRetainedIDsTogether() async throws {
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let originalSource = try await repository.prepareImport(from: makeFixture())
        let incoming = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(originalSource); PDFService.discard(incoming) }
        let id = UUID()
        let created = try await repository.create(id: id, details: NotebookDetails(name: "Original"), from: [originalSource])
        let original = try XCTUnwrap(created.manifest.notebooks.first)
        let newPageID = UUID()
        let layout = [
            DraftPage(id: newPageID, source: .prepared(incoming.id, 1)),
            DraftPage(id: original.pages[0].id, source: .existing(original.pages[0].id))
        ]
        let edited = try await repository.edit(
            id, details: NotebookDetails(name: "Arranged", colorID: "green"), appending: [incoming], pageLayout: layout
        )
        let saved = try XCTUnwrap(edited.manifest.notebooks.first)
        XCTAssertEqual(saved.pages.map(\.id), layout.map(\.id))
        XCTAssertEqual(saved.name, "Arranged")
        XCTAssertEqual(saved.colorID, "green")
        let document = try PDFService.validate(at: XCTUnwrap(repository.pdfURL(for: saved)))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Second vector page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("First vector page") == true)
        XCTAssertEqual(document.page(at: 1)?.annotations.first?.contents, "A preserved note")
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .cropBox), CGRect(x: 10, y: 20, width: 360, height: 540))
        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reopened.manifest.notebooks.first?.pages, saved.pages)
    }

    func testArrangingAllPagesAwayRejectsNewButCanEmptyExistingNotebook() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        let incoming = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(incoming) }
        do {
            _ = try await repository.create(id: UUID(), details: NotebookDetails(name: "Empty"), from: [incoming], pageLayout: [])
            XCTFail("A new notebook needs retained pages")
        } catch PDFError.emptyDocument { }
        let emptied = try await repository.edit(sample.id, details: sample.details, appending: [incoming], pageLayout: [])
        let saved = emptied.manifest.notebooks[0]
        XCTAssertTrue(saved.pages.isEmpty)
        XCTAssertNil(saved.revisionID)
        XCTAssertNil(repository.pdfURL(for: saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.url.path))
    }

    func testInvalidDraftSourcesCannotChangeSavedLibrary() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        let incoming = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(incoming) }
        let existingID = sample.pages[0].id
        let newID = UUID()
        let valid = DraftPage(id: newID, source: .prepared(incoming.id, 0))
        let invalidLayouts = [
            [DraftPage(id: UUID(), source: .existing(UUID()))],
            [DraftPage(id: UUID(), source: .existing(existingID))],
            [DraftPage(id: UUID(), source: .prepared(UUID(), 0))],
            [DraftPage(id: UUID(), source: .prepared(incoming.id, -1))],
            [DraftPage(id: UUID(), source: .prepared(incoming.id, incoming.pageCount))],
            [DraftPage(id: existingID, source: .prepared(incoming.id, 0))],
            [valid, DraftPage(id: newID, source: .prepared(incoming.id, 1))],
            [valid, DraftPage(id: UUID(), source: .prepared(incoming.id, 0))]
        ]
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        for layout in invalidLayouts {
            do {
                _ = try await repository.edit(sample.id, details: NotebookDetails(name: "Changed"), appending: [incoming], pageLayout: layout)
                XCTFail("Expected invalid source rejection")
            } catch LibraryError.invalidChange { }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
        }
        do {
            _ = try await repository.create(id: UUID(), details: NotebookDetails(name: "Invalid"), from: [incoming], pageLayout: [DraftPage(id: existingID, source: .existing(existingID))])
            XCTFail("A new notebook cannot reference saved pages")
        } catch LibraryError.invalidChange { }
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded.manifest.notebooks, initial.manifest.notebooks)
    }

    func testRemovingAllIncomingPagesLeavesExistingPDFBytesUntouched() async throws {
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = initial.manifest.notebooks[0]
        let incoming = try await repository.prepareImport(from: makeFixture())
        defer { PDFService.discard(incoming) }
        let originalBytes = try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: sample)))
        let layout = sample.pages.map { DraftPage(id: $0.id, source: .existing($0.id)) }
        let edited = try await repository.edit(sample.id, details: NotebookDetails(name: "Metadata"), appending: [incoming], pageLayout: layout)
        let saved = edited.manifest.notebooks[0]
        XCTAssertEqual(saved.revisionID, sample.revisionID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(repository.pdfURL(for: saved))), originalBytes)
    }

    private func legacyManifest(_ notebooks: [Notebook]) throws -> Data {
        let encoded = try JSONEncoder().encode(LibraryManifest(notebooks: notebooks))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["schemaVersion"] = 1
        var entries = try XCTUnwrap(json["notebooks"] as? [[String: Any]])
        for index in entries.indices {
            entries[index].removeValue(forKey: "symbolName")
            entries[index].removeValue(forKey: "colorID")
            entries[index].removeValue(forKey: "isArchived")
        }
        json["notebooks"] = entries
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private func makeFixture() throws -> URL {
        let url = folder.appendingPathComponent("fixture-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for title in ["First vector page", "Second vector page"] {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 50, y: 50, width: 200, height: 100))
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let string = NSAttributedString(string: title, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            context.textPosition = CGPoint(x: 50, y: 500)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try PDFService.validate(at: url)
        for index in 0..<document.pageCount {
            document.page(at: index)?.setBounds(CGRect(x: 10, y: 20, width: 360, height: 540), for: .cropBox)
        }
        let annotation = PDFAnnotation(bounds: CGRect(x: 70, y: 200, width: 100, height: 40), forType: .text, withProperties: nil)
        annotation.contents = "A preserved note"
        document.page(at: 0)?.addAnnotation(annotation)
        try PDFService.write(document, to: url)
        return url
    }

    private func makeOrientationFixture() throws -> URL {
        let url = folder.appendingPathComponent("orientation.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 240, width: 50, height: 60))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func pixel(in image: CGImage, xFraction: Double, yFraction: Double) throws -> (red: UInt8, green: UInt8) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (Int(Double(height) * yFraction) * width + Int(Double(width) * xFraction)) * 4
        return (data[offset], data[offset + 1])
    }
}

private enum TestFailure: Error {
    case injected
}
