import Foundation
import Observation

@MainActor
@Observable
final class ReadingPositionStore {
    private struct Position: Codable, Equatable {
        let pageID: UUID
        let index: Int
    }

    static let positionsKey = "readingPositions"
    @ObservationIgnored private let defaults: UserDefaults
    private var positions: [String: Position]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        positions = defaults.data(forKey: Self.positionsKey)
            .flatMap { try? JSONDecoder().decode([String: Position].self, from: $0) } ?? [:]
    }

    func pageID(for notebookID: UUID, in pageIDs: [UUID], requestedPageID: UUID? = nil) -> UUID? {
        if let requestedPageID, pageIDs.contains(requestedPageID) { return requestedPageID }
        guard !pageIDs.isEmpty else { return nil }
        guard let position = positions[notebookID.uuidString] else { return pageIDs.first }
        if pageIDs.contains(position.pageID) { return position.pageID }
        return pageIDs[min(max(position.index, 0), pageIDs.count - 1)]
    }

    func remember(pageID: UUID?, in pageIDs: [UUID], for notebookID: UUID) {
        guard let pageID, let index = pageIDs.firstIndex(of: pageID) else { return }
        let position = Position(pageID: pageID, index: index)
        guard positions[notebookID.uuidString] != position else { return }
        positions[notebookID.uuidString] = position
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: Self.positionsKey)
        }
    }
}

// Zoom lasts only for this reader visit, including window size changes.
@MainActor
@Observable
final class ReaderSession {
    var relativeZoom: CGFloat = 1
    var pageID: UUID?
    var selectionRequestID: UUID?
}
