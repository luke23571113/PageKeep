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

    func notebook(id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    func pdfURL(for notebook: Notebook) -> URL? {
        repository.pdfURL(for: notebook)
    }

    func savePrepared(
        _ prepared: PreparedPDF,
        name: String,
        notebookID: UUID?
    ) async throws -> UUID {
        let id = notebookID ?? UUID()
        try await perform {
            if notebookID != nil {
                return try await repository.append(to: id, from: prepared)
            }
            return try await repository.create(id: id, name: name, from: prepared)
        }
        return id
    }

    func rename(_ id: UUID, to name: String) async throws {
        try await perform { try await repository.rename(id, to: name) }
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
        notebooks = snapshot.manifest.notebooks.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        notebookErrors = snapshot.notebookErrors
    }
}

private enum LibraryActionError: LocalizedError {
    case busy

    var errorDescription: String? {
        "Please wait for the current change to finish."
    }
}
