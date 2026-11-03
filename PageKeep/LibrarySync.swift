import Foundation
import CryptoKit

struct NotebookContentVersion: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let parentIDs: Set<UUID>
    let revisionID: UUID?
    let pages: [NotebookPage]
}

struct SyncClock: Codable, Sendable, Equatable, Comparable {
    var counter: UInt64 = 0
    var deviceID: String = ""

    static func < (lhs: SyncClock, rhs: SyncClock) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID < rhs.deviceID
    }
}

struct NotebookFieldClocks: Codable, Sendable, Equatable {
    var name = SyncClock()
    var symbol = SyncClock()
    var color = SyncClock()
    var archived = SyncClock()
    var folder = SyncClock()

    private enum CodingKeys: String, CodingKey { case name, symbol, color, archived, folder }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(SyncClock.self, forKey: .name)
        symbol = try values.decode(SyncClock.self, forKey: .symbol)
        color = try values.decode(SyncClock.self, forKey: .color)
        archived = try values.decode(SyncClock.self, forKey: .archived)
        folder = try values.decodeIfPresent(SyncClock.self, forKey: .folder) ?? SyncClock()
    }
}

struct NotebookTombstone: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { notebook.id }
    let notebook: Notebook
    let clock: SyncClock
}

struct FolderTombstone: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let clock: SyncClock
}

struct NotebookOrderMove: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let notebookID: UUID
    let beforeID: UUID?
    let eligibleIDs: Set<UUID>
    let clock: SyncClock
    var includesArchived = false
    var scoped = false
    var folderID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, notebookID, beforeID, eligibleIDs, clock, includesArchived, scoped, folderID
    }

    init(id: UUID, notebookID: UUID, beforeID: UUID?, eligibleIDs: Set<UUID>, clock: SyncClock,
         includesArchived: Bool = false, scoped: Bool = false, folderID: UUID? = nil) {
        self.id = id
        self.notebookID = notebookID
        self.beforeID = beforeID
        self.eligibleIDs = eligibleIDs
        self.clock = clock
        self.includesArchived = includesArchived
        self.scoped = scoped
        self.folderID = folderID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        notebookID = try values.decode(UUID.self, forKey: .notebookID)
        beforeID = try values.decodeIfPresent(UUID.self, forKey: .beforeID)
        eligibleIDs = try values.decode(Set<UUID>.self, forKey: .eligibleIDs)
        clock = try values.decode(SyncClock.self, forKey: .clock)
        includesArchived = try values.decodeIfPresent(Bool.self, forKey: .includesArchived) ?? false
        scoped = try values.decodeIfPresent(Bool.self, forKey: .scoped) ?? false
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
    }
}

struct SyncOutboxEntry: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let notebook: Notebook?
    let tombstone: NotebookTombstone?
    let move: NotebookOrderMove?
    var clock = SyncClock()
    var folder: NotebookFolder? = nil
    var folderTombstone: FolderTombstone? = nil
}

struct LibrarySyncNotice: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case conflict, recovered, metadataConflict }
    let id: UUID
    let notebookID: UUID
    let kind: Kind
    var details: String? = nil
}

struct LibrarySyncState: Codable, Sendable {
    var deviceID = UUID().uuidString
    var orderSeedID = UUID().uuidString
    var baseOrder: [UUID] = []
    var logicalClock: UInt64 = 0
    var needsBootstrap = true
    var outbox: [SyncOutboxEntry] = []
    var tombstones: [NotebookTombstone] = []
    var folderTombstones: [FolderTombstone] = []
    var orderMoves: [NotebookOrderMove] = []
    var notices: [LibrarySyncNotice] = []
    var dismissedNoticeIDs: Set<UUID> = []

    private enum CodingKeys: String, CodingKey {
        case deviceID, orderSeedID, baseOrder, logicalClock, needsBootstrap, outbox, tombstones
        case folderTombstones, orderMoves, notices, dismissedNoticeIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        orderSeedID = try values.decode(String.self, forKey: .orderSeedID)
        baseOrder = try values.decode([UUID].self, forKey: .baseOrder)
        logicalClock = try values.decode(UInt64.self, forKey: .logicalClock)
        needsBootstrap = try values.decode(Bool.self, forKey: .needsBootstrap)
        outbox = try values.decode([SyncOutboxEntry].self, forKey: .outbox)
        tombstones = try values.decode([NotebookTombstone].self, forKey: .tombstones)
        folderTombstones = try values.decodeIfPresent([FolderTombstone].self, forKey: .folderTombstones) ?? []
        orderMoves = try values.decode([NotebookOrderMove].self, forKey: .orderMoves)
        notices = try values.decode([LibrarySyncNotice].self, forKey: .notices)
        dismissedNoticeIDs = try values.decode(Set<UUID>.self, forKey: .dismissedNoticeIDs)
    }

    mutating func nextClock() -> SyncClock {
        logicalClock += 1
        return SyncClock(counter: logicalClock, deviceID: deviceID)
    }
}

// Reconciliation only chooses durable records. The repository validates PDFs before committing them.
enum LibraryReconciliation {
    static func merge(_ local: LibraryManifest, with remote: LibraryManifest) -> LibraryManifest {
        var result = local
        result.sync.logicalClock = max(local.sync.logicalClock, remote.sync.logicalClock)
        recordMetadataConflicts(local, remote: remote, state: &result.sync)
        let folderDeletes = Dictionary((local.sync.folderTombstones + remote.sync.folderTombstones).map { ($0.id, $0) },
                                      uniquingKeysWith: { $0.clock < $1.clock ? $1 : $0 })
        result.sync.folderTombstones = folderDeletes.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let folderRecords = Dictionary((local.folders + remote.folders).filter { folderDeletes[$0.id] == nil }.map { ($0.id, $0) },
                                       uniquingKeysWith: { left, right in
            if left.nameClock != right.nameClock { return left.nameClock < right.nameClock ? right : left }
            return left.syncName < right.syncName ? right : left
        })
        var namedFolders: [NotebookFolder] = []
        for var folder in folderRecords.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            folder.requestedName = folder.syncName
            folder.name = (try? NotebookNaming.resolvedFolderName(folder.syncName, in: namedFolders)) ?? folder.syncName
            namedFolders.append(folder)
        }
        result.folders = namedFolders
        let tombstones = mergedTombstones(local.sync.tombstones + remote.sync.tombstones)
        result.sync.tombstones = tombstones
        let deleted = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.id, $0) })
        var candidates: [Notebook] = []
        for notebook in local.notebooks + remote.notebooks {
            if let tombstone = deleted[notebook.id] {
                if hasEdits(notebook, after: tombstone.notebook) {
                    let recovered = recoveredCopy(notebook, tombstone: tombstone)
                    candidates.append(recovered)
                    addNotice(.recovered, notebook: recovered, state: &result.sync)
                }
            } else if let sourceID = notebook.recoverySourceID,
                      let tombstone = deleted[sourceID],
                      !hasEdits(notebook, after: tombstone.notebook) {
                // A later deletion can cover an edit that was already recovered.
                continue
            } else {
                candidates.append(notebook)
            }
        }
        var notebooks: [UUID: Notebook] = [:]
        var recoveredBranches: [Notebook] = []
        let groups = Dictionary(grouping: candidates) { $0.conflictOriginID ?? $0.id }
        for (origin, versions) in groups {
            for notebook in mergedBranches(versions, origin: origin) {
                if let tombstone = deleted[notebook.id] {
                    if hasEdits(notebook, after: tombstone.notebook) {
                        recoveredBranches.append(recoveredCopy(notebook, tombstone: tombstone))
                    }
                } else {
                    notebooks[notebook.id] = notebook
                    if notebook.id != origin { addNotice(.conflict, notebook: notebook, state: &result.sync) }
                }
            }
        }
        for (origin, branches) in Dictionary(grouping: recoveredBranches, by: { $0.id }) {
            let existing = notebooks.values.filter { $0.id == origin || $0.conflictOriginID == origin }
            for notebook in mergedBranches(branches + existing, origin: origin) {
                notebooks[notebook.id] = notebook
                addNotice(.recovered, notebook: notebook, state: &result.sync)
            }
        }
        let moves = Dictionary((local.sync.orderMoves + remote.sync.orderMoves).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.sync.orderMoves = moves.values.sorted(by: movePrecedes)
        let seed = local.sync.orderSeedID < remote.sync.orderSeedID ? local.sync : remote.sync
        result.sync.orderSeedID = seed.orderSeedID
        result.sync.baseOrder = seed.baseOrder
        let allIDs = Set(notebooks.keys).union(result.folders.map(\.id))
        var ids = seed.baseOrder.filter { allIDs.contains($0) }
        ids.append(contentsOf: allIDs.filter { !ids.contains($0) }.sorted { $0.uuidString < $1.uuidString })
        result.notebooks = Array(notebooks.values)
        for move in result.sync.orderMoves {
            let groupIDs: Set<UUID>
            if move.scoped {
                result.itemOrder = ids
                groupIDs = Set(result.itemIDs(in: move.folderID, includingArchived: move.includesArchived))
            } else {
                groupIDs = Set(notebooks.values.filter { move.includesArchived || !$0.isArchived }.map(\.id))
            }
            let slots = ids.indices.filter { move.eligibleIDs.contains(ids[$0]) && groupIDs.contains(ids[$0]) }
            var eligible = slots.map { ids[$0] }
            guard eligible.contains(move.notebookID) else { continue }
            eligible.removeAll { $0 == move.notebookID }
            let index = move.beforeID.flatMap { eligible.firstIndex(of: $0) } ?? eligible.endIndex
            eligible.insert(move.notebookID, at: index)
            for (slot, id) in zip(slots, eligible) { ids[slot] = id }
        }
        result.itemOrder = ids
        // Resolve displayed duplicates from the original requested names on every merge.
        var named: [Notebook] = []
        for id in notebooks.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var notebook = notebooks[id] else { continue }
            notebook.name = (try? NotebookNaming.resolvedName(notebook.name, in: named)) ?? notebook.name
            notebooks[id] = notebook
            named.append(notebook)
        }
        result.notebooks = ids.compactMap { notebooks[$0] }
        return result
    }

    private static func mergedBranches(_ candidates: [Notebook], origin: UUID) -> [Notebook] {
        let history = Dictionary(candidates.flatMap(\.contentHistory).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allVersions = history.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let heads = candidates.filter { candidate in
            !candidates.contains { $0.contentVersionID != candidate.contentVersionID && $0.contentAncestors.contains(candidate.contentVersionID) }
        }
        let byHead = Dictionary(grouping: heads, by: \.contentVersionID)
        return byHead.map { versionID, values in
            var selected = values.sorted { $0.id.uuidString < $1.id.uuidString }[0]
            for candidate in candidates where candidate.contentVersionID == versionID || selected.contentAncestors.contains(candidate.contentVersionID) {
                selected = mergeMetadata(selected, candidate)
            }
            let identity = branchIdentity(for: versionID, origin: origin, history: history)
            let isCopy = identity != origin
            let name = selected.syncName + (selected.recoverySourceID == nil ? "" : " (Recovered)") + (isCopy ? " (Conflict)" : "")
            return Notebook(
                id: identity, name: name, createdAt: selected.createdAt, modifiedAt: selected.modifiedAt,
                revisionID: selected.revisionID, pages: selected.pages, symbolName: selected.symbolName,
                colorID: selected.colorID, isArchived: selected.isArchived, contentVersionID: versionID,
                contentAncestors: selected.contentAncestors, contentHistory: allVersions,
                conflictOriginID: isCopy ? origin : nil, recoverySourceID: selected.recoverySourceID,
                requestedName: selected.syncName, folderID: selected.folderID, fieldClocks: selected.fieldClocks
            )
        }
    }

    private static func branchIdentity(for head: UUID, origin: UUID, history: [UUID: NotebookContentVersion]) -> UUID {
        var path: [UUID] = []
        var cursor: UUID? = head
        var visited = Set<UUID>()
        while let current = cursor, visited.insert(current).inserted {
            path.append(current)
            cursor = history[current]?.parentIDs.sorted { $0.uuidString < $1.uuidString }.first
        }
        var identity = origin
        for version in path.reversed() {
            let parent = history[version]?.parentIDs.first
            let siblings = history.values.filter { $0.parentIDs.first == parent }.map(\.id)
            if let winner = siblings.max(by: { $0.uuidString < $1.uuidString }), version != winner {
                identity = stableID("conflict|\(origin)|\(version)")
            }
        }
        return identity
    }

    private static func mergeMetadata(_ lhs: Notebook, _ rhs: Notebook) -> Notebook {
        var result = lhs
        if rhs.fieldClocks.name > lhs.fieldClocks.name || (rhs.fieldClocks.name == lhs.fieldClocks.name && rhs.syncName > lhs.syncName) {
            result.name = rhs.name
            result.requestedName = rhs.syncName
            result.fieldClocks.name = rhs.fieldClocks.name
        } else { result.name = lhs.name; result.requestedName = lhs.syncName; result.fieldClocks.name = lhs.fieldClocks.name }
        if rhs.fieldClocks.symbol > lhs.fieldClocks.symbol || (rhs.fieldClocks.symbol == lhs.fieldClocks.symbol && rhs.symbolName > lhs.symbolName) {
            result.symbolName = rhs.symbolName
            result.fieldClocks.symbol = rhs.fieldClocks.symbol
        } else { result.symbolName = lhs.symbolName; result.fieldClocks.symbol = lhs.fieldClocks.symbol }
        if rhs.fieldClocks.color > lhs.fieldClocks.color || (rhs.fieldClocks.color == lhs.fieldClocks.color && rhs.colorID > lhs.colorID) {
            result.colorID = rhs.colorID
            result.fieldClocks.color = rhs.fieldClocks.color
        } else { result.colorID = lhs.colorID; result.fieldClocks.color = lhs.fieldClocks.color }
        if rhs.fieldClocks.archived > lhs.fieldClocks.archived || (rhs.fieldClocks.archived == lhs.fieldClocks.archived && rhs.isArchived) {
            result.isArchived = rhs.isArchived
            result.fieldClocks.archived = rhs.fieldClocks.archived
        } else { result.isArchived = lhs.isArchived; result.fieldClocks.archived = lhs.fieldClocks.archived }
        let leftFolder = lhs.folderID?.uuidString ?? ""
        let rightFolder = rhs.folderID?.uuidString ?? ""
        if rhs.fieldClocks.folder > lhs.fieldClocks.folder || (rhs.fieldClocks.folder == lhs.fieldClocks.folder && rightFolder > leftFolder) {
            result.folderID = rhs.folderID
            result.fieldClocks.folder = rhs.fieldClocks.folder
        }
        result.modifiedAt = max(lhs.modifiedAt, rhs.modifiedAt)
        return result
    }

    private static func hasEdits(_ notebook: Notebook, after deleted: Notebook) -> Bool {
        let contentChanged = !deleted.contentHistory.contains { $0.id == notebook.contentVersionID }
        return contentChanged || notebook.fieldClocks.name > deleted.fieldClocks.name
            || notebook.fieldClocks.symbol > deleted.fieldClocks.symbol
            || notebook.fieldClocks.color > deleted.fieldClocks.color
            || notebook.fieldClocks.archived > deleted.fieldClocks.archived
            || notebook.fieldClocks.folder > deleted.fieldClocks.folder
    }

    private static func recoveredCopy(_ notebook: Notebook, tombstone: NotebookTombstone) -> Notebook {
        let key = "recovered|\(tombstone.id)"
        return Notebook(
            id: stableID(key), name: notebook.syncName + " (Recovered)",
            createdAt: notebook.createdAt, modifiedAt: notebook.modifiedAt, revisionID: notebook.revisionID,
            pages: notebook.pages, symbolName: notebook.symbolName, colorID: notebook.colorID,
            isArchived: notebook.isArchived, contentVersionID: notebook.contentVersionID,
            contentAncestors: notebook.contentAncestors,
            contentHistory: notebook.contentHistory.filter { $0.id == notebook.contentVersionID || notebook.contentAncestors.contains($0.id) },
            recoverySourceID: tombstone.id, requestedName: notebook.syncName, folderID: notebook.folderID, fieldClocks: notebook.fieldClocks
        )
    }

    private static func recordMetadataConflicts(_ local: LibraryManifest, remote: LibraryManifest, state: inout LibrarySyncState) {
        for left in local.notebooks {
            guard let right = remote.notebooks.first(where: { $0.id == left.id }) else { continue }
            let pending = local.sync.outbox.filter { $0.notebook?.id == left.id }
            let fields = [
                ("Name", left.syncName, right.syncName, left.fieldClocks.name, right.fieldClocks.name),
                ("Symbol", left.symbolName, right.symbolName, left.fieldClocks.symbol, right.fieldClocks.symbol),
                ("Color", left.colorID, right.colorID, left.fieldClocks.color, right.fieldClocks.color),
                ("Archived", String(left.isArchived), String(right.isArchived), left.fieldClocks.archived, right.fieldClocks.archived),
                ("Folder", left.folderID?.uuidString ?? "No Folder", right.folderID?.uuidString ?? "No Folder", left.fieldClocks.folder, right.fieldClocks.folder)
            ]
            for (field, lhs, rhs, leftClock, rightClock) in fields {
                guard lhs != rhs, rightClock.counter > 0, leftClock != rightClock,
                      leftClock.deviceID != rightClock.deviceID,
                      pending.contains(where: { $0.clock == leftClock }) else { continue }
                let winner = max(leftClock, rightClock)
                let loser = min(leftClock, rightClock)
                let noticeID = stableID("metadata|\(left.id)|\(field)|\(winner.counter)|\(winner.deviceID)|\(loser.counter)|\(loser.deviceID)")
                guard !state.dismissedNoticeIDs.contains(noticeID), !state.notices.contains(where: { $0.id == noticeID }) else { continue }
                let value: String
                if field == "Folder" {
                    if let folderID = leftClock < rightClock ? left.folderID : right.folderID {
                        value = (local.folders + remote.folders).first { $0.id == folderID }?.name ?? "Unavailable Folder"
                    } else {
                        value = "No Folder"
                    }
                } else {
                    value = leftClock < rightClock ? lhs : rhs
                }
                state.notices.append(LibrarySyncNotice(id: noticeID, notebookID: left.id, kind: .metadataConflict, details: "\(field) also changed on another device. Previous value: \(value)"))
            }
        }
    }

    private static func addNotice(_ kind: LibrarySyncNotice.Kind, notebook: Notebook, state: inout LibrarySyncState) {
        guard !state.dismissedNoticeIDs.contains(notebook.id), !state.notices.contains(where: { $0.id == notebook.id }) else { return }
        state.notices.append(LibrarySyncNotice(id: notebook.id, notebookID: notebook.id, kind: kind))
    }

    private static func mergedTombstones(_ values: [NotebookTombstone]) -> [NotebookTombstone] {
        Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: mergeTombstones)
            .values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func mergeTombstones(_ lhs: NotebookTombstone, _ rhs: NotebookTombstone) -> NotebookTombstone {
        let latest = lhs.clock < rhs.clock ? rhs : lhs
        var notebook = latest.notebook
        // Keep every version that another device explicitly deleted.
        let history = Dictionary(
            (lhs.notebook.contentHistory + rhs.notebook.contentHistory).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        notebook.contentHistory = history.values.sorted { $0.id.uuidString < $1.id.uuidString }
        notebook.fieldClocks.name = max(lhs.notebook.fieldClocks.name, rhs.notebook.fieldClocks.name)
        notebook.fieldClocks.symbol = max(lhs.notebook.fieldClocks.symbol, rhs.notebook.fieldClocks.symbol)
        notebook.fieldClocks.color = max(lhs.notebook.fieldClocks.color, rhs.notebook.fieldClocks.color)
        notebook.fieldClocks.archived = max(lhs.notebook.fieldClocks.archived, rhs.notebook.fieldClocks.archived)
        notebook.fieldClocks.folder = max(lhs.notebook.fieldClocks.folder, rhs.notebook.fieldClocks.folder)
        return NotebookTombstone(notebook: notebook, clock: latest.clock)
    }

    private static func movePrecedes(_ lhs: NotebookOrderMove, _ rhs: NotebookOrderMove) -> Bool {
        if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func stableID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
