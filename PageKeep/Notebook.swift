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
    var contentVersionID: UUID
    var contentAncestors: Set<UUID> = []
    var contentHistory: [NotebookContentVersion] = []
    var conflictOriginID: UUID?
    var recoverySourceID: UUID?
    var requestedName: String?
    var folderID: UUID?
    var fieldClocks: NotebookFieldClocks = NotebookFieldClocks()

    init(
        id: UUID, name: String, createdAt: Date, modifiedAt: Date,
        revisionID: UUID?, pages: [NotebookPage], symbolName: String = "book.closed",
        colorID: String = "default", isArchived: Bool = false,
        contentVersionID: UUID? = nil, contentAncestors: Set<UUID> = [],
        contentHistory: [NotebookContentVersion] = [], conflictOriginID: UUID? = nil,
        recoverySourceID: UUID? = nil, requestedName: String? = nil,
        folderID: UUID? = nil, fieldClocks: NotebookFieldClocks = NotebookFieldClocks()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revisionID = revisionID
        self.pages = pages
        self.symbolName = symbolName
        self.colorID = colorID
        self.isArchived = isArchived
        self.contentVersionID = contentVersionID ?? revisionID ?? id
        self.contentAncestors = contentAncestors
        self.contentHistory = contentHistory.isEmpty ? [NotebookContentVersion(
            id: self.contentVersionID, parentIDs: [], revisionID: revisionID, pages: pages
        )] : contentHistory
        self.conflictOriginID = conflictOriginID
        self.recoverySourceID = recoverySourceID
        self.requestedName = requestedName
        self.folderID = folderID
        self.fieldClocks = fieldClocks
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, revisionID, pages, symbolName, colorID, isArchived
        case contentVersionID, contentAncestors, contentHistory, conflictOriginID, recoverySourceID, requestedName, folderID, fieldClocks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let revision = try values.decodeIfPresent(UUID.self, forKey: .revisionID)
        self.init(
            id: id, name: try values.decode(String.self, forKey: .name),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            modifiedAt: try values.decode(Date.self, forKey: .modifiedAt),
            revisionID: revision, pages: try values.decode([NotebookPage].self, forKey: .pages),
            symbolName: try values.decode(String.self, forKey: .symbolName),
            colorID: try values.decode(String.self, forKey: .colorID),
            isArchived: try values.decode(Bool.self, forKey: .isArchived),
            contentVersionID: try values.decodeIfPresent(UUID.self, forKey: .contentVersionID),
            contentAncestors: try values.decodeIfPresent(Set<UUID>.self, forKey: .contentAncestors) ?? [],
            contentHistory: try values.decodeIfPresent([NotebookContentVersion].self, forKey: .contentHistory) ?? [],
            conflictOriginID: try values.decodeIfPresent(UUID.self, forKey: .conflictOriginID),
            recoverySourceID: try values.decodeIfPresent(UUID.self, forKey: .recoverySourceID),
            requestedName: try values.decodeIfPresent(String.self, forKey: .requestedName),
            folderID: try values.decodeIfPresent(UUID.self, forKey: .folderID),
            fieldClocks: try values.decodeIfPresent(NotebookFieldClocks.self, forKey: .fieldClocks) ?? NotebookFieldClocks()
        )
    }

    var syncName: String { requestedName ?? name }

    var details: NotebookDetails {
        NotebookDetails(name: name, symbolName: symbolName, colorID: colorID, folderID: folderID)
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

struct NotebookFolder: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var requestedName: String? = nil
    var nameClock = SyncClock()

    var syncName: String { requestedName ?? name }
}

enum LibraryItem: Identifiable, Sendable, Equatable {
    case folder(NotebookFolder)
    case notebook(Notebook)

    var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .notebook(let notebook): notebook.id
        }
    }
}

struct LibraryManifest: Codable, Sendable {
    var schemaVersion: Int = 4
    var initialized: Bool = true
    var notebooks: [Notebook]
    var folders: [NotebookFolder]
    var itemOrder: [UUID]
    var sync: LibrarySyncState = LibrarySyncState()

    private enum CodingKeys: String, CodingKey { case schemaVersion, initialized, notebooks, folders, itemOrder, sync }

    init(notebooks: [Notebook], folders: [NotebookFolder] = [], itemOrder: [UUID]? = nil, sync: LibrarySyncState? = nil) {
        self.notebooks = notebooks
        self.folders = folders
        self.itemOrder = itemOrder ?? notebooks.map(\.id) + folders.map(\.id)
        self.sync = sync ?? LibrarySyncState()
        if sync == nil { self.sync.baseOrder = self.itemOrder }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = 4
        initialized = try values.decode(Bool.self, forKey: .initialized)
        notebooks = try values.decode([Notebook].self, forKey: .notebooks)
        folders = try values.decodeIfPresent([NotebookFolder].self, forKey: .folders) ?? []
        itemOrder = try values.decodeIfPresent([UUID].self, forKey: .itemOrder) ?? notebooks.map(\.id)
        if let savedSync = try values.decodeIfPresent(LibrarySyncState.self, forKey: .sync) {
            sync = savedSync
        } else {
            sync = LibrarySyncState()
            sync.baseOrder = itemOrder
        }
    }

    func effectiveFolderID(for notebook: Notebook) -> UUID? {
        guard let id = notebook.folderID, folders.contains(where: { $0.id == id }),
              !sync.folderTombstones.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func itemIDs(in folderID: UUID?, includingArchived: Bool = false) -> [UUID] {
        let notebookIDs = Set(notebooks.filter {
            (includingArchived || !$0.isArchived) && effectiveFolderID(for: $0) == folderID
        }.map(\.id))
        let folderIDs = folderID == nil ? Set(folders.map(\.id)) : []
        return itemOrder.filter { notebookIDs.contains($0) || folderIDs.contains($0) }
    }
}

struct LibrarySnapshot: Sendable {
    let manifest: LibraryManifest
    let notebookErrors: [UUID: String]
    var savedNotebookID: UUID? = nil
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
    var folderID: UUID? = nil
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
