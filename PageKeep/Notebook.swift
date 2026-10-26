import Foundation

struct Notebook: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var revisionID: UUID?
    var pages: [NotebookPage]
    var symbolName: String = "book.closed"
    var colorID: String = "default"
    var isArchived: Bool = false

    var details: NotebookDetails {
        NotebookDetails(name: name, symbolName: symbolName, colorID: colorID)
    }

    var pageCount: Int { pages.count }

    var pageCountLabel: String {
        pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }
}

struct NotebookPage: Codable, Identifiable, Sendable, Equatable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct LibraryManifest: Codable, Sendable {
    var schemaVersion: Int = 2
    var initialized: Bool = true
    var notebooks: [Notebook]
}

struct LibrarySnapshot: Sendable {
    let manifest: LibraryManifest
    let notebookErrors: [UUID: String]
}

// V1 had no appearance, archive state, or saved manual order.
struct LegacyLibraryManifest: Decodable {
    let initialized: Bool
    let notebooks: [LegacyNotebook]

    func migrated() -> LibraryManifest {
        let migrated = notebooks.map {
            Notebook(
                id: $0.id, name: $0.name, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt,
                revisionID: $0.revisionID, pages: $0.pages
            )
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return LibraryManifest(notebooks: migrated)
    }
}

struct LegacyNotebook: Decodable {
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let revisionID: UUID?
    let pages: [NotebookPage]
}

struct PreparedPDF: Identifiable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let suggestedName: String
    let pageCount: Int

    init(id: UUID = UUID(), url: URL, suggestedName: String, pageCount: Int) {
        self.id = id
        self.url = url
        self.suggestedName = suggestedName
        self.pageCount = pageCount
    }
}

struct NotebookDetails: Sendable, Equatable {
    var name: String
    var symbolName: String = "book.closed"
    var colorID: String = "default"
}

struct SavedNotebook: Sendable {
    let notebookID: UUID
    let firstAddedPageID: UUID?
}

struct DraftPage: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Hashable {
        case existing(UUID)
        case prepared(UUID, Int)
    }

    let id: UUID
    let source: Source
}
