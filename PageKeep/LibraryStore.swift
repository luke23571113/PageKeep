import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    let repository: LibraryRepository
    private(set) var notebooks: [Notebook] = []
    private(set) var folders: [NotebookFolder] = []
    private var itemOrder: [UUID] = []
    private(set) var notebookErrors: [UUID: String] = [:]
    private(set) var isLoading = true
    private(set) var isBusy = false
    private(set) var loadError: String?
    private(set) var canRecover = false
    private(set) var syncNotices: [LibrarySyncNotice] = []
    private(set) var pendingSyncCount = 0
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

    var rootItems: [LibraryItem] {
        let folderItems = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, LibraryItem.folder($0)) })
        let notebookItems = Dictionary(uniqueKeysWithValues: notebooks(in: nil).map { ($0.id, LibraryItem.notebook($0)) })
        return itemOrder.compactMap { folderItems[$0] ?? notebookItems[$0] }
    }

    func notebooks(in folderID: UUID?) -> [Notebook] {
        let matches = Dictionary(uniqueKeysWithValues: notebooks.filter {
            !$0.isArchived && effectiveFolderID(for: $0) == folderID
        }.map { ($0.id, $0) })
        return itemOrder.compactMap { matches[$0] }
    }

    func folder(id: UUID) -> NotebookFolder? { folders.first { $0.id == id } }

    func effectiveFolderID(for notebook: Notebook) -> UUID? {
        guard let id = notebook.folderID, folder(id: id) != nil else { return nil }
        return id
    }

    func folderName(for notebook: Notebook) -> String? {
        effectiveFolderID(for: notebook).flatMap { folder(id: $0)?.name }
    }

    func createFolder(name: String) async throws -> UUID {
        let id = UUID()
        try await perform { try await repository.createFolder(id: id, name: name) }
        return id
    }

    func renameFolder(_ id: UUID, name: String) async throws {
        try await perform { try await repository.renameFolder(id, name: name) }
    }

    func deleteFolder(_ id: UUID) async throws {
        try await perform { try await repository.deleteFolder(id) }
    }

    func moveNotebook(_ id: UUID, toFolderID folderID: UUID?) async throws {
        try await perform { try await repository.moveNotebook(id, toFolderID: folderID) }
    }

    func reorderItems(inFolderID folderID: UUID?, orderedIDs: [UUID]) async throws {
        try await perform { try await repository.reorderItems(inFolderID: folderID, orderedIDs: orderedIDs) }
    }

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
        expectedExistingPageIDs: [UUID]? = nil,
        baseNotebook: Notebook? = nil, basePDFURL: URL? = nil, draftVersionID: UUID? = nil
    ) async throws -> SavedNotebook {
        let id = notebookID ?? UUID()
        var savedID = id
        try await perform {
            if notebookID != nil {
                let result = try await repository.edit(
                    id, details: details, appending: additions, pageLayout: pageLayout,
                    expectedExistingPageIDs: expectedExistingPageIDs, baseNotebook: baseNotebook,
                    basePDFURL: basePDFURL, draftVersionID: draftVersionID
                )
                savedID = result.savedNotebookID ?? id
                return result
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
        } else if addedCount > 0, let saved = notebook(id: savedID) {
            firstAddedPageID = saved.pages[saved.pageCount - addedCount].id
        }
        return SavedNotebook(notebookID: savedID, firstAddedPageID: firstAddedPageID)
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

    func applyRemote(_ manifest: LibraryManifest, downloadedPDFs: [UUID: URL]) async throws {
        try await perform { try await repository.reconcile(with: manifest, downloadedPDFs: downloadedPDFs) }
    }

    func acknowledgeSyncEntries(_ ids: Set<UUID>) async throws {
        try await perform { try await repository.acknowledgeSyncEntries(ids) }
    }

    func prepareForSync() async throws {
        try await perform { try await repository.prepareForSync() }
    }

    func resetSyncForNewAccount() async throws {
        try await perform { try await repository.resetSyncForNewAccount() }
    }

    func dismissSyncNotice(_ id: UUID) async throws {
        try await perform { try await repository.dismissSyncNotice(id) }
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
        folders = snapshot.manifest.folders
        itemOrder = snapshot.manifest.itemOrder
        notebookErrors = snapshot.notebookErrors
        syncNotices = snapshot.manifest.sync.notices
        pendingSyncCount = snapshot.manifest.sync.outbox.count
    }
}

private enum LibraryActionError: LocalizedError {
    case busy

    var errorDescription: String? {
        "Please wait for the current change to finish."
    }
}
