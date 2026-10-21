import Foundation

struct Notebook: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var revisionID: UUID?
    var pages: [NotebookPage]

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
    var schemaVersion: Int = 1
    var initialized: Bool = true
    var notebooks: [Notebook]
}

struct LibrarySnapshot: Sendable {
    let manifest: LibraryManifest
    let notebookErrors: [UUID: String]
}

struct PreparedPDF: Identifiable, Sendable {
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
