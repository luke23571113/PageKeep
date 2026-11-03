import Foundation
import Observation

@MainActor
@Observable
final class NotebookDraft {
    var details: NotebookDetails
    private(set) var additions: [PreparedPDF]
    private(set) var pages: [DraftPage]
    private(set) var isSaving = false
    private let versionID = UUID()
    let baseNotebook: Notebook?
    let pinnedPDFURL: URL?
    private let ownedPDFURL: URL?
    private let originalDetails: NotebookDetails
    private let existingPages: [DraftPage]
    private var uneditedPages: [DraftPage]

    init(
        details: NotebookDetails, additions: [PreparedPDF] = [],
        existingNotebook: Notebook? = nil, savedURL: URL? = nil
    ) {
        baseNotebook = existingNotebook
        // A hard link keeps the opened revision alive even after library cleanup.
        if let savedURL, let pinned = Self.pinSource(savedURL) {
            pinnedPDFURL = pinned
            ownedPDFURL = pinned
        } else {
            pinnedPDFURL = nil
            ownedPDFURL = nil
        }
        self.details = details
        originalDetails = details
        self.additions = additions
        let savedPages = existingNotebook?.pages.map { DraftPage(id: $0.id, source: .existing($0.id)) } ?? []
        existingPages = savedPages
        let incoming = additions.flatMap { prepared in
            (0..<prepared.pageCount).map { DraftPage(id: UUID(), source: .prepared(prepared.id, $0)) }
        }
        let allPages = savedPages + incoming
        pages = allPages
        uneditedPages = allPages
    }

    deinit {
        if let ownedPDFURL { try? FileManager.default.removeItem(at: ownedPDFURL.deletingLastPathComponent()) }
    }

    private static func pinSource(_ source: URL) -> URL? {
        guard let destination = try? PDFService.makeStagingURL() else { return nil }
        do {
            do { try FileManager.default.linkItem(at: source, to: destination) }
            catch { try FileManager.default.copyItem(at: source, to: destination) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            return nil
        }
    }

    var hasChanges: Bool { details != originalDetails || !additions.isEmpty || pageLayoutChanged }
    var pageCount: Int { pages.count }
    var pageLayoutChanged: Bool { pages != uneditedPages }
    var pendingPageCount: Int {
        pages.filter {
            if case .prepared = $0.source { return true }
            return false
        }.count
    }

    func add(_ prepared: PreparedPDF) {
        guard !isSaving else { return }
        additions.append(prepared)
        let incoming = (0..<prepared.pageCount).map { DraftPage(id: UUID(), source: .prepared(prepared.id, $0)) }
        pages.append(contentsOf: incoming)
        uneditedPages.append(contentsOf: incoming)
    }

    func reorderPages(orderedIDs: [UUID]) throws {
        try requireEditable()
        guard orderedIDs.count == pages.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(pages.map(\.id)) else { throw LibraryError.invalidChange }
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        pages = orderedIDs.compactMap { byID[$0] }
    }

    func removePages(ids: Set<UUID>) throws {
        try requireEditable()
        guard ids.isSubset(of: Set(pages.map(\.id))) else { throw LibraryError.invalidChange }
        pages.removeAll { ids.contains($0.id) }
    }

    func movePages(ids: Set<UUID>, before destinationID: UUID?) throws {
        try requireEditable()
        guard ids.isSubset(of: Set(pages.map(\.id))),
              destinationID.map({ id in pages.contains { $0.id == id } && !ids.contains(id) }) ?? true else {
            throw LibraryError.invalidChange
        }
        let selected = pages.filter { ids.contains($0.id) }
        var remaining = pages.filter { !ids.contains($0.id) }
        let destination = destinationID.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.endIndex
        remaining.insert(contentsOf: selected, at: destination)
        pages = remaining
    }

    func save(in store: LibraryStore, notebookID: UUID?) async throws -> SavedNotebook {
        try requireEditable()
        isSaving = true
        defer { isSaving = false }
        let result = try await store.saveNotebook(
            details: details, notebookID: notebookID, additions: additions,
            pageLayout: pageLayoutChanged ? pages : nil,
            expectedExistingPageIDs: pageLayoutChanged ? existingPages.map(\.id) : nil,
            baseNotebook: baseNotebook, basePDFURL: pinnedPDFURL, draftVersionID: versionID
        )
        await clearPendingPages(in: store.repository)
        return result
    }

    func discardPendingPages(in repository: LibraryRepository) async {
        guard !isSaving else { return }
        await clearPendingPages(in: repository)
    }

    private func clearPendingPages(in repository: LibraryRepository) async {
        let discarded = additions
        additions = []
        pages = existingPages
        uneditedPages = existingPages
        for prepared in discarded { await repository.discardPrepared(prepared) }
    }

    private func requireEditable() throws {
        guard !isSaving else { throw NotebookDraftError.alreadySaving }
    }
}

private enum NotebookDraftError: LocalizedError {
    case alreadySaving

    var errorDescription: String? { "This notebook is already being saved. Please wait." }
}
