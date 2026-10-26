import Foundation

struct DraftPagePreviewSource {
    let url: URL
    let pageIndex: Int
}

struct DraftPagePreviewSources {
    private let existingIndices: [UUID: Int]
    private let savedURL: URL?
    private let batches: [UUID: PreparedPDF]

    init(notebook: Notebook?, savedURL: URL?, additions: [PreparedPDF]) {
        existingIndices = Dictionary((notebook?.pages ?? []).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.savedURL = savedURL
        batches = Dictionary(additions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func source(for page: DraftPage) -> DraftPagePreviewSource? {
        switch page.source {
        case let .existing(id):
            guard let savedURL, let index = existingIndices[id] else { return nil }
            return DraftPagePreviewSource(url: savedURL, pageIndex: index)
        case let .prepared(batchID, index):
            guard let batch = batches[batchID], (0..<batch.pageCount).contains(index) else { return nil }
            return DraftPagePreviewSource(url: batch.url, pageIndex: index)
        }
    }
}

struct DraftPreviewRequest: Equatable, Sendable {
    let pages: [DraftPage]
    let notebook: Notebook?
    let savedURL: URL?
    let additions: [PreparedPDF]

    func sourcesExist() -> Bool {
        guard !pages.isEmpty else { return false }
        let sources = DraftPagePreviewSources(notebook: notebook, savedURL: savedURL, additions: additions)
        let resolved = pages.compactMap { sources.source(for: $0) }
        guard resolved.count == pages.count else { return false }
        return Set(resolved.map(\.url)).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}
