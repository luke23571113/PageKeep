import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    let repository: LibraryRepository
    private(set) var notebooks: [Notebook] = []
    private(set) var notebookErrors: [UUID: String] = [:]
    private(set) var isLoading = true
    private(set) var isBusy = false
    private(set) var loadError: String?
    private(set) var canRecover = false
    private var hasLoaded = false

    init(repository: LibraryRepository = LibraryRepository()) {
        self.repository = repository
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        guard !isBusy else { return }
        isLoading = true
        isBusy = true
        defer {
            isLoading = false
            isBusy = false
        }
        do {
            update(try await repository.load())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            canRecover = await repository.canRecover()
        }
    }

    func recover() async {
        guard !isBusy else { return }
        isBusy = true
        isLoading = true
        defer {
            isBusy = false
            isLoading = false
        }
        do {
            update(try await repository.recover())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    var activeNotebooks: [Notebook] { notebooks.filter { !$0.isArchived } }
    var archivedNotebooks: [Notebook] { notebooks.filter(\.isArchived) }

    func notebook(id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    func pdfURL(for notebook: Notebook) -> URL? {
        repository.pdfURL(for: notebook)
    }

    func saveNotebook(
        details: NotebookDetails,
        notebookID: UUID?,
        additions: [PreparedPDF],
        pageLayout: [DraftPage]? = nil,
        expectedExistingPageIDs: [UUID]? = nil
    ) async throws -> SavedNotebook {
        let id = notebookID ?? UUID()
        try await perform {
            if notebookID != nil {
                return try await repository.edit(
                    id, details: details, appending: additions, pageLayout: pageLayout,
                    expectedExistingPageIDs: expectedExistingPageIDs
                )
            }
            return try await repository.create(id: id, details: details, from: additions, pageLayout: pageLayout)
        }
        let addedCount = additions.reduce(0) { $0 + $1.pageCount }
        var firstAddedPageID: UUID?
        if let pageLayout {
            firstAddedPageID = pageLayout.first {
                if case .prepared = $0.source { return true }
                return false
            }?.id
        } else if addedCount > 0, let saved = notebook(id: id) {
            firstAddedPageID = saved.pages[saved.pageCount - addedCount].id
        }
        return SavedNotebook(notebookID: id, firstAddedPageID: firstAddedPageID)
    }

    func reorderNotebooks(orderedActiveIDs: [UUID]) async throws {
        try await perform { try await repository.reorderNotebooks(orderedActiveIDs: orderedActiveIDs) }
    }

    func setArchived(_ archived: Bool, ids: Set<UUID>) async throws {
        try await perform { try await repository.setArchived(archived, ids: ids) }
    }

    func appendPrepared(_ prepared: PreparedPDF, to notebookID: UUID) async throws -> SavedNotebook {
        let existingCount = notebook(id: notebookID)?.pageCount ?? 0
        try await perform { try await repository.append(to: notebookID, from: prepared) }
        let firstAddedPageID = notebook(id: notebookID)?.pages.dropFirst(existingCount).first?.id
        return SavedNotebook(notebookID: notebookID, firstAddedPageID: firstAddedPageID)
    }

    func deleteNotebook(_ id: UUID) async throws {
        try await perform { try await repository.deleteNotebook(id) }
    }

    func reorderPages(in id: UUID, orderedIDs: [UUID]) async throws {
        try await perform {
            try await repository.reorderPages(in: id, orderedIDs: orderedIDs)
        }
    }

    func rotatePages(in id: UUID, ids: Set<UUID>) async throws {
        try await perform { try await repository.rotatePages(in: id, ids: ids) }
    }

    func deletePages(in id: UUID, ids: Set<UUID>) async throws {
        try await perform { try await repository.deletePages(in: id, ids: ids) }
    }

    func shareCopy(of id: UUID) async throws -> URL {
        guard !isBusy else { throw LibraryActionError.busy }
        isBusy = true
        defer { isBusy = false }
        return try await repository.shareCopy(of: id)
    }

    private func perform(_ operation: () async throws -> LibrarySnapshot) async throws {
        guard !isBusy else { throw LibraryActionError.busy }
        isBusy = true
        defer { isBusy = false }
        update(try await operation())
    }

    private func update(_ snapshot: LibrarySnapshot) {
        notebooks = snapshot.manifest.notebooks
        notebookErrors = snapshot.notebookErrors
    }
}

private enum LibraryActionError: LocalizedError {
    case busy

    var errorDescription: String? {
        "Please wait for the current change to finish."
    }
}
