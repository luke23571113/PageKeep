import XCTest
import PDFKit
import SwiftUI
@testable import PageKeep

@MainActor
final class ReaderSettingsTests: XCTestCase {
    func testPageNumberPreferenceDefaultsToVisibleAndPersists() throws {
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showsPageNumber)

        settings.showsPageNumber = false
        XCTAssertFalse(defaults.bool(forKey: AppSettings.showsPageNumberKey))
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showsPageNumber)

        reloaded.showsPageNumber = true
        XCTAssertTrue(AppSettings(defaults: defaults).showsPageNumber)
    }

    func testPreferencesDefaultAndPersistAsRawStrings() throws {
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.readingMode, .vertical)
        XCTAssertNil(settings.appearance.colorScheme)
        settings.appearance = .dark
        settings.readingMode = .horizontal
        XCTAssertEqual(defaults.string(forKey: AppSettings.appearanceKey), "dark")
        XCTAssertEqual(defaults.string(forKey: AppSettings.readingModeKey), "horizontal")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.readingMode, .horizontal)
        XCTAssertEqual(reloaded.appearance.colorScheme, .dark)
        settings.appearance = .light
        XCTAssertEqual(AppSettings(defaults: defaults).appearance.colorScheme, .light)
    }

    func testUnknownPreferencesFallBackToDefaults() throws {
        let suiteName = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-appearance", forKey: AppSettings.appearanceKey)
        defaults.set("future-mode", forKey: AppSettings.readingModeKey)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.readingMode, .vertical)
    }

    func testReaderTeardownRemovesItsInteractionGestures() {
        let reader = PDFReader(
            url: URL(fileURLWithPath: "/test.pdf"), pageIDs: [], currentPageID: .constant(nil),
            readingMode: .vertical, onInteraction: {}
        )
        let view = PDFReaderView()
        let coordinator = reader.makeCoordinator()
        coordinator.view = view
        let originalGestureCount = view.pdfView.gestureRecognizers?.count ?? 0
        coordinator.observeInteractions(in: view.pdfView)
        XCTAssertEqual(view.pdfView.gestureRecognizers?.count, originalGestureCount + 3)
        PDFReader.dismantleUIView(view, coordinator: coordinator)
        XCTAssertEqual(view.pdfView.gestureRecognizers?.count ?? 0, originalGestureCount)
        XCTAssertNil(coordinator.view)
        XCTAssertNil(coordinator.loading)
    }

    func testReplacementLoadIgnoresNotificationsFromPreviousDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("first.pdf")
        let secondURL = folder.appendingPathComponent("second.pdf")
        try PDFService.writeSample(to: firstURL)
        try PDFService.writeSample(to: secondURL)
        let ids = [UUID(), UUID(), UUID()]
        var selection: UUID? = ids[0]
        let binding = Binding<UUID?>(get: { selection }, set: { selection = $0 })
        let first = PDFReader(url: firstURL, pageIDs: ids, currentPageID: binding, readingMode: .vertical, onInteraction: {})
        let coordinator = first.makeCoordinator()
        let view = PDFReaderView()
        coordinator.view = view
        coordinator.update(first)
        let deadline = Date().addingTimeInterval(5)
        while coordinator.loading != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(view.pdfView.document)
        let replacement = PDFReader(url: secondURL, pageIDs: Array(ids.reversed()), currentPageID: binding, readingMode: .vertical, onInteraction: {})
        coordinator.update(replacement)
        coordinator.pageChanged()
        XCTAssertEqual(selection, ids[0])
        while coordinator.loading != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await Task.yield()
        XCTAssertEqual(selection, ids[0])
        XCTAssertEqual(view.pdfView.document?.index(for: try XCTUnwrap(view.pdfView.currentPage)), 2)
        coordinator.stop()
    }

    func testKeyboardZoomPreservesTheDocumentAndPage() throws {
        let view = PDFReaderView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        document.insert(page, at: 0)
        view.pdfView.document = document
        view.layoutIfNeeded()
        view.pdfView.minScaleFactor = 0.25
        view.pdfView.maxScaleFactor = 4
        view.pdfView.scaleFactor = 1

        view.zoomIn()
        XCTAssertGreaterThan(view.pdfView.scaleFactor, 1)
        view.zoomOut()
        XCTAssertEqual(view.pdfView.scaleFactor, 1, accuracy: 0.01)
        view.fitPage()
        XCTAssertTrue(view.pdfView.autoScales)
        XCTAssertTrue(view.pdfView.document === document)
        XCTAssertTrue(view.pdfView.currentPage === page)
        XCTAssertEqual(Set(view.keyCommands?.compactMap(\.input) ?? []), ["+", "=", "-", "0"])
    }

    func testReadingModeChangesKeepTheDocumentAndPage() throws {
        let url = URL(fileURLWithPath: "/test.pdf")
        let ids = [UUID(), UUID()]
        let document = PDFDocument()
        for index in 0..<2 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
            document.insert(page, at: index)
        }
        let selectedPage = try XCTUnwrap(document.page(at: 1))
        let view = PDFReaderView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        view.pdfView.document = document
        view.pdfView.go(to: selectedPage)
        let horizontal = PDFReader(url: url, pageIDs: ids, currentPageID: .constant(ids[1]), readingMode: .horizontal, onInteraction: {})
        let coordinator = horizontal.makeCoordinator()
        coordinator.view = view
        coordinator.loadedURL = url
        coordinator.update(horizontal)
        XCTAssertTrue(view.pdfView.document === document)
        XCTAssertTrue(view.pdfView.currentPage === selectedPage)
        XCTAssertTrue(view.pdfView.isUsingPageViewController)
        XCTAssertEqual(view.pdfView.backgroundColor, UIColor.systemBackground)

        let vertical = PDFReader(url: url, pageIDs: ids, currentPageID: .constant(ids[1]), readingMode: .vertical, onInteraction: {})
        coordinator.update(vertical)
        XCTAssertTrue(view.pdfView.document === document)
        XCTAssertTrue(view.pdfView.currentPage === selectedPage)
        XCTAssertFalse(view.pdfView.isUsingPageViewController)
        XCTAssertEqual(view.pdfView.displayMode, .singlePageContinuous)
        XCTAssertEqual(view.pdfView.backgroundColor, UIColor.secondarySystemBackground)
    }
}
