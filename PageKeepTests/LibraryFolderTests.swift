import XCTest
@testable import PageKeep

@MainActor
final class LibraryFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PageKeepFolders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFolderMetadataPersistsWithoutChangingNotebookContent() async throws {
        let a = notebook("A")
        try seed([a])
        let repository = LibraryRepository(rootURL: root)
        let folderID = UUID()
        _ = try await repository.createFolder(id: folderID, name: "School")
        let moved = try await repository.moveNotebook(a.id, toFolderID: folderID)
        let saved = try XCTUnwrap(moved.manifest.notebooks.first)
        XCTAssertEqual(saved.revisionID, a.revisionID)
        XCTAssertEqual(saved.pages, a.pages)
        XCTAssertEqual(saved.contentVersionID, a.contentVersionID)
        XCTAssertEqual(saved.folderID, folderID)
        XCTAssertGreaterThan(saved.fieldClocks.folder.counter, 0)
        XCTAssertTrue(moved.manifest.sync.outbox.contains { $0.folder?.id == folderID })
        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reopened.manifest.folders.first?.name, "School")
        XCTAssertEqual(reopened.manifest.notebooks.first?.folderID, folderID)
        XCTAssertEqual(reopened.manifest.itemOrder, moved.manifest.itemOrder)
    }

    func testFolderReorderOnlyChangesItsProjectionAndMovesAppend() async throws {
        let a = notebook("A"), b = notebook("B"), c = notebook("C")
        try seed([a, b, c])
        let repository = LibraryRepository(rootURL: root)
        let folderID = UUID()
        _ = try await repository.createFolder(id: folderID, name: "Work")
        _ = try await repository.moveNotebook(a.id, toFolderID: folderID)
        _ = try await repository.moveNotebook(c.id, toFolderID: folderID)
        let reordered = try await repository.reorderItems(inFolderID: folderID, orderedIDs: [c.id, a.id])
        XCTAssertEqual(reordered.manifest.itemIDs(in: nil), [b.id, folderID])
        XCTAssertEqual(reordered.manifest.itemIDs(in: folderID), [c.id, a.id])
        let moved = try await repository.moveNotebook(c.id, toFolderID: nil)
        XCTAssertEqual(moved.manifest.itemIDs(in: nil), [b.id, folderID, c.id])
        XCTAssertEqual(moved.manifest.itemIDs(in: folderID), [a.id])
    }

    func testDeleteFolderAppendsChildrenAndPreservesArchiveState() async throws {
        let a = notebook("A"), b = notebook("B"), c = notebook("C")
        try seed([a, b, c])
        let repository = LibraryRepository(rootURL: root)
        let folderID = UUID()
        _ = try await repository.createFolder(id: folderID, name: "Work")
        _ = try await repository.moveNotebook(a.id, toFolderID: folderID)
        _ = try await repository.moveNotebook(c.id, toFolderID: folderID)
        _ = try await repository.setArchived(true, ids: [c.id])
        let deleted = try await repository.deleteFolder(folderID)
        XCTAssertTrue(deleted.manifest.folders.isEmpty)
        XCTAssertEqual(deleted.manifest.itemIDs(in: nil), [b.id, a.id])
        XCTAssertEqual(deleted.manifest.itemIDs(in: nil, includingArchived: true), [b.id, a.id, c.id])
        XCTAssertTrue(deleted.manifest.notebooks.first { $0.id == c.id }?.isArchived == true)
        XCTAssertTrue(deleted.manifest.notebooks.allSatisfy { $0.folderID == nil })
        XCTAssertEqual(deleted.manifest.sync.folderTombstones.map(\.id), [folderID])
        XCTAssertTrue(deleted.manifest.sync.tombstones.isEmpty)
    }

    func testFailedFolderCommitDoesNotChangeManifestOrOutbox() async throws {
        try seed([notebook("A")])
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let repository = LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeManifestCommit = checkpoint { throw FolderFailure.injected }
        }
        do {
            _ = try await repository.createFolder(name: "Work")
            XCTFail("Expected injected failure")
        } catch FolderFailure.injected { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertTrue(reopened.manifest.folders.isEmpty)
        XCTAssertTrue(reopened.manifest.sync.outbox.isEmpty)
    }

    func testVersionThreeMigrationKeepsManualOrderAndQueuedEdits() async throws {
        let a = notebook("A"), b = notebook("B")
        var state = LibrarySyncState()
        state.outbox = [SyncOutboxEntry(id: UUID(), notebook: a, tombstone: nil, move: nil)]
        let original = LibraryManifest(notebooks: [b, a], sync: state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 3
        object.removeValue(forKey: "folders")
        object.removeValue(forKey: "itemOrder")
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("manifest.json"))
        let migrated = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(migrated.manifest.schemaVersion, 4)
        XCTAssertTrue(migrated.manifest.folders.isEmpty)
        XCTAssertEqual(migrated.manifest.itemOrder, [b.id, a.id])
        XCTAssertEqual(migrated.manifest.sync.outbox, state.outbox)
    }

    func testSuppliedEmptySeedSurvivesVersionThreeAndFourReload() async throws {
        let a = notebook("A"), b = notebook("B")
        let folder = NotebookFolder(id: UUID(), name: "Work")
        var state = LibrarySyncState()
        state.orderSeedID = "saved-empty-seed"
        for version in [3, 4] {
            let folders = version == 4 ? [folder] : []
            let order = version == 4 ? [folder.id, b.id, a.id] : [b.id, a.id]
            let original = LibraryManifest(notebooks: [b, a], folders: folders, itemOrder: order, sync: state)
            XCTAssertTrue(original.sync.baseOrder.isEmpty)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object["schemaVersion"] = version
            if version == 3 {
                object.removeValue(forKey: "folders")
                object.removeValue(forKey: "itemOrder")
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: root.appendingPathComponent("manifest.json"))
            try data.write(to: root.appendingPathComponent("manifest.backup.json"))
            let reopened = try await LibraryRepository(rootURL: root).load()
            XCTAssertEqual(reopened.manifest.itemOrder, order)
            XCTAssertTrue(reopened.manifest.sync.baseOrder.isEmpty)
            XCTAssertEqual(reopened.manifest.sync.orderSeedID, state.orderSeedID)
        }
    }

    func testNewAndLegacyLibrariesInitializeSeedFromManualOrder() async throws {
        let a = notebook("A"), b = notebook("B")
        let original = LibraryManifest(notebooks: [b, a])
        XCTAssertEqual(original.sync.baseOrder, [b.id, a.id])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "sync")
        object.removeValue(forKey: "folders")
        object.removeValue(forKey: "itemOrder")
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("manifest.json"))
        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reopened.manifest.itemOrder, [b.id, a.id])
        XCTAssertEqual(reopened.manifest.sync.baseOrder, [b.id, a.id])
    }

    func testFolderConflictNoticeUsesNamesAndKeepsIdentityForUnavailableFolder() throws {
        let work = NotebookFolder(id: UUID(), name: "Work")
        let school = NotebookFolder(id: UUID(), name: "School")
        var left = notebook("A")
        left.folderID = work.id
        left.fieldClocks.folder = SyncClock(counter: 1, deviceID: "local")
        var right = left
        right.folderID = school.id
        right.fieldClocks.folder = SyncClock(counter: 2, deviceID: "remote")
        var local = LibraryManifest(notebooks: [left], folders: [work, school])
        local.sync.outbox = [SyncOutboxEntry(id: UUID(), notebook: left, tombstone: nil, move: nil, clock: left.fieldClocks.folder)]
        let remote = LibraryManifest(notebooks: [right], folders: [school])
        let named = LibraryReconciliation.merge(local, with: remote)
        let namedNotice = try XCTUnwrap(named.sync.notices.first { $0.kind == .metadataConflict })
        XCTAssertEqual(namedNotice.details, "Folder also changed on another device. Previous value: Work")

        local.folders.removeAll { $0.id == work.id }
        local.itemOrder.removeAll { $0 == work.id }
        let unavailable = LibraryReconciliation.merge(local, with: remote)
        let unavailableNotice = try XCTUnwrap(unavailable.sync.notices.first { $0.kind == .metadataConflict })
        XCTAssertEqual(unavailableNotice.details, "Folder also changed on another device. Previous value: Unavailable Folder")
        XCTAssertEqual(unavailableNotice.id, namedNotice.id)

        local.notebooks[0].folderID = nil
        let noFolder = LibraryReconciliation.merge(local, with: remote)
        XCTAssertEqual(noFolder.sync.notices.first { $0.kind == .metadataConflict }?.details,
                       "Folder also changed on another device. Previous value: No Folder")
    }

    func testUnchangedDraftDoesNotUndoMoveAndDeletedChoiceBecomesRoot() async throws {
        let a = notebook("A")
        try seed([a])
        let repository = LibraryRepository(rootURL: root)
        let folderID = UUID()
        _ = try await repository.createFolder(id: folderID, name: "Work")
        _ = try await repository.moveNotebook(a.id, toFolderID: folderID)
        var draft = a.details
        draft.colorID = "green"
        let edited = try await repository.edit(a.id, details: draft, appending: [], baseNotebook: a)
        XCTAssertEqual(edited.manifest.notebooks.first?.folderID, folderID)
        _ = try await repository.deleteFolder(folderID)
        draft.folderID = folderID
        let deletedChoice = try await repository.edit(a.id, details: draft, appending: [], baseNotebook: a)
        XCTAssertNil(deletedChoice.manifest.notebooks.first?.folderID)
    }

    func testMissingFolderReferenceProjectsToRootUntilFolderArrives() {
        var a = notebook("A")
        let folder = NotebookFolder(id: UUID(), name: "Work")
        a.folderID = folder.id
        let local = LibraryManifest(notebooks: [a])
        XCTAssertEqual(local.itemIDs(in: nil), [a.id])
        XCTAssertEqual(local.notebooks.first?.folderID, folder.id)
        let merged = LibraryReconciliation.merge(local, with: LibraryManifest(notebooks: [], folders: [folder]))
        XCTAssertEqual(merged.itemIDs(in: folder.id), [a.id])
    }

    func testFolderRenameDeletionAndAssignmentConverge() {
        let folder = NotebookFolder(id: UUID(), name: "Work")
        var a = notebook("A")
        a.folderID = folder.id
        a.fieldClocks.folder = SyncClock(counter: 5, deviceID: "a")
        var left = LibraryManifest(notebooks: [a], folders: [folder])
        var renamed = folder
        renamed.name = "Renamed"
        renamed.nameClock = SyncClock(counter: 9, deviceID: "b")
        let right = LibraryManifest(notebooks: [a], folders: [renamed])
        left.folders = []
        left.itemOrder.removeAll { $0 == folder.id }
        left.sync.folderTombstones = [FolderTombstone(id: folder.id, clock: SyncClock(counter: 6, deviceID: "a"))]
        let ab = LibraryReconciliation.merge(left, with: right)
        let ba = LibraryReconciliation.merge(right, with: left)
        XCTAssertEqual(ab.folders, ba.folders)
        XCTAssertTrue(ab.folders.isEmpty)
        XCTAssertNil(ab.effectiveFolderID(for: a))
        XCTAssertEqual(ab.notebooks, ba.notebooks)
    }

    func testSameNamedFoldersStaySeparateAndNamesDoNotAccumulateSuffixes() {
        let a = NotebookFolder(id: UUID(), name: "Work")
        let b = NotebookFolder(id: UUID(), name: "Work")
        let left = LibraryManifest(notebooks: [], folders: [a])
        let right = LibraryManifest(notebooks: [], folders: [b])
        let merged = LibraryReconciliation.merge(left, with: right)
        let replay = LibraryReconciliation.merge(merged, with: right)
        XCTAssertEqual(Set(merged.folders.map(\.id)), [a.id, b.id])
        XCTAssertEqual(Set(merged.folders.map(\.name)), ["Work", "Work (1)"])
        XCTAssertEqual(merged.folders, replay.folders)
        XCTAssertEqual(merged.folders, LibraryReconciliation.merge(right, with: left).folders)
    }

    func testAccountResetKeepsFoldersAndMembership() async throws {
        let a = notebook("A")
        try seed([a])
        let repository = LibraryRepository(rootURL: root)
        let folderID = UUID()
        _ = try await repository.createFolder(id: folderID, name: "Work")
        _ = try await repository.moveNotebook(a.id, toFolderID: folderID)
        let reset = try await repository.resetSyncForNewAccount()
        XCTAssertEqual(reset.manifest.folders.map(\.id), [folderID])
        XCTAssertEqual(reset.manifest.notebooks.first?.folderID, folderID)
        XCTAssertTrue(reset.manifest.sync.folderTombstones.isEmpty)
        XCTAssertTrue(reset.manifest.sync.outbox.contains { $0.folder?.id == folderID })
    }

    private func notebook(_ name: String) -> Notebook {
        Notebook(id: UUID(), name: name, createdAt: .distantPast, modifiedAt: .distantPast, revisionID: nil, pages: [])
    }

    private func seed(_ notebooks: [Notebook]) throws {
        let data = try JSONEncoder().encode(LibraryManifest(notebooks: notebooks))
        try data.write(to: root.appendingPathComponent("manifest.json"))
        try data.write(to: root.appendingPathComponent("manifest.backup.json"))
    }
}

private enum FolderFailure: Error { case injected }
