import XCTest
@testable import PageKeep

final class LibraryFolderSyncTests: XCTestCase {
    func testSameNameFoldersKeepSeparateIDsAndStableSuffixesAcrossReplay() {
        let first = folder(500, name: "Math")
        let second = folder(501, name: "Math")
        let left = manifest([], folders: [first])
        let right = manifest([], folders: [second])
        let merged = LibraryReconciliation.merge(left, with: right)

        XCTAssertEqual(merged.folders.map(\.id), [first.id, second.id])
        XCTAssertEqual(merged.folders.map(\.name), ["Math", "Math (1)"])
        XCTAssertEqual(merged.folders.map(\.syncName), ["Math", "Math"])
        XCTAssertEqual(LibraryReconciliation.merge(right, with: left).folders, merged.folders)
        XCTAssertEqual(LibraryReconciliation.merge(merged, with: left).folders, merged.folders)
        XCTAssertEqual(LibraryReconciliation.merge(merged, with: right).folders, merged.folders)
        XCTAssertEqual(LibraryReconciliation.merge(merged, with: merged).folders, merged.folders)
    }

    func testConcurrentFolderRenameAndNotebookFieldsConvergeIndependently() throws {
        var leftFolder = folder(500, name: "Calculus")
        leftFolder.nameClock = SyncClock(counter: 5, deviceID: "a")
        var rightFolder = leftFolder
        rightFolder.name = "Algebra"
        rightFolder.nameClock = SyncClock(counter: 5, deviceID: "b")
        let otherFolder = folder(501, name: "Projects")
        var leftNotebook = notebook(1, folderID: leftFolder.id)
        leftNotebook.name = "Lecture Notes"
        leftNotebook.fieldClocks.name = SyncClock(counter: 3, deviceID: "a")
        leftNotebook.fieldClocks.folder = SyncClock(counter: 4, deviceID: "a")
        var rightNotebook = notebook(1, folderID: otherFolder.id)
        rightNotebook.colorID = "green"
        rightNotebook.fieldClocks.color = SyncClock(counter: 3, deviceID: "b")
        rightNotebook.fieldClocks.folder = SyncClock(counter: 4, deviceID: "b")
        let left = manifest([leftNotebook], folders: [leftFolder, otherFolder])
        let right = manifest([rightNotebook], folders: [rightFolder, otherFolder])

        for pair in [(left, right), (right, left)] {
            let merged = LibraryReconciliation.merge(pair.0, with: pair.1)
            let saved = try XCTUnwrap(merged.notebooks.first)
            XCTAssertEqual(merged.folders.first { $0.id == leftFolder.id }?.name, "Algebra")
            XCTAssertEqual(saved.name, "Lecture Notes")
            XCTAssertEqual(saved.colorID, "green")
            XCTAssertEqual(saved.folderID, otherFolder.id)
            XCTAssertEqual(saved.fieldClocks.folder, rightNotebook.fieldClocks.folder)
            XCTAssertEqual(saved.contentVersionID, leftNotebook.contentVersionID)
            XCTAssertEqual(saved, LibraryReconciliation.merge(merged, with: left).notebooks.first)
            XCTAssertEqual(saved, LibraryReconciliation.merge(merged, with: right).notebooks.first)
        }
    }

    func testFolderDeletionWinsAgainstRenameAndLateMoveWithoutDeletingPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageKeepFolderSync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = try XCTUnwrap(initial.manifest.notebooks.first)
        let pdfURL = try XCTUnwrap(repository.pdfURL(for: sample))
        let originalPDF = try Data(contentsOf: pdfURL)
        let destination = folder(500, name: "Math")
        _ = try await repository.createFolder(id: destination.id, name: destination.name)
        let assigned = try await repository.moveNotebook(sample.id, toFolderID: destination.id)
        var lateNotebook = try XCTUnwrap(assigned.manifest.notebooks.first)
        lateNotebook.fieldClocks.folder = SyncClock(counter: 100, deviceID: "offline")
        var renamed = destination
        renamed.name = "Offline Rename"
        renamed.nameClock = SyncClock(counter: 100, deviceID: "offline")
        let late = manifest([lateNotebook], folders: [renamed])
        let deleted = try await repository.deleteFolder(destination.id)

        XCTAssertTrue(deleted.manifest.folders.isEmpty)
        XCTAssertNil(deleted.manifest.notebooks.first?.folderID)
        XCTAssertTrue(deleted.manifest.sync.outbox.contains { $0.folderTombstone?.id == destination.id })
        let reconciled = try await repository.reconcile(with: late, downloadedPDFs: [:])
        let saved = try XCTUnwrap(reconciled.manifest.notebooks.first)
        XCTAssertEqual(reconciled.manifest.notebooks.count, 1)
        XCTAssertTrue(reconciled.manifest.folders.isEmpty)
        XCTAssertEqual(saved.folderID, destination.id)
        XCTAssertNil(reconciled.manifest.effectiveFolderID(for: saved))
        XCTAssertEqual(reconciled.manifest.itemIDs(in: nil), [sample.id])
        XCTAssertEqual(saved.revisionID, sample.revisionID)
        XCTAssertEqual(saved.pages, sample.pages)
        XCTAssertEqual(try Data(contentsOf: pdfURL), originalPDF)

        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reopened.manifest.notebooks, reconciled.manifest.notebooks)
        XCTAssertTrue(reopened.manifest.folders.isEmpty)
        XCTAssertEqual(try Data(contentsOf: pdfURL), originalPDF)
        XCTAssertTrue(LibraryReconciliation.merge(late, with: reopened.manifest).folders.isEmpty)
    }

    func testMissingFolderRetainsMembershipUntilFolderArrives() throws {
        let destination = folder(500, name: "Math")
        var assigned = notebook(1, folderID: destination.id)
        assigned.fieldClocks.folder = SyncClock(counter: 4, deviceID: "offline")
        let missing = manifest([assigned])
        let pending = LibraryReconciliation.merge(manifest([]), with: missing)
        let saved = try XCTUnwrap(pending.notebooks.first)
        XCTAssertEqual(saved.folderID, destination.id)
        XCTAssertEqual(saved.fieldClocks.folder, assigned.fieldClocks.folder)
        XCTAssertNil(pending.effectiveFolderID(for: saved))
        XCTAssertEqual(pending.itemIDs(in: nil), [assigned.id])

        let arrived = LibraryReconciliation.merge(pending, with: manifest([], folders: [destination]))
        XCTAssertEqual(arrived.notebooks.first?.folderID, destination.id)
        XCTAssertEqual(arrived.notebooks.first?.fieldClocks.folder, assigned.fieldClocks.folder)
        XCTAssertEqual(arrived.notebooks.first?.revisionID, assigned.revisionID)
        XCTAssertEqual(arrived.effectiveFolderID(for: saved), destination.id)
        XCTAssertEqual(arrived.itemIDs(in: nil), [destination.id])
        XCTAssertEqual(arrived.itemIDs(in: destination.id), [assigned.id])
        let replay = LibraryReconciliation.merge(arrived, with: missing)
        XCTAssertEqual(replay.notebooks, arrived.notebooks)
        XCTAssertEqual(replay.folders, arrived.folders)
        XCTAssertEqual(replay.itemOrder, arrived.itemOrder)
    }

    func testConcurrentRootAndChildReordersStayInsideTheirParents() {
        let firstFolder = folder(500, name: "Math")
        let secondFolder = folder(501, name: "Projects")
        let rootFirst = notebook(1)
        let firstChild = notebook(2, folderID: firstFolder.id)
        let lastChild = notebook(3, folderID: firstFolder.id)
        let rootLast = notebook(4)
        let otherChild = notebook(5, folderID: secondFolder.id)
        var archived = notebook(6, folderID: firstFolder.id)
        archived.isArchived = true
        let order = [rootFirst.id, firstChild.id, firstFolder.id, otherChild.id,
                     lastChild.id, archived.id, secondFolder.id, rootLast.id]
        let notebooks = [rootFirst, firstChild, lastChild, rootLast, otherChild, archived]
        var rootMove = manifest(notebooks, folders: [firstFolder, secondFolder], order: order)
        rootMove.sync.orderMoves = [NotebookOrderMove(
            id: id(900), notebookID: secondFolder.id, beforeID: rootFirst.id,
            eligibleIDs: Set(order), clock: SyncClock(counter: 3, deviceID: "a"), scoped: true
        )]
        var childMove = manifest(notebooks, folders: [firstFolder, secondFolder], order: order)
        childMove.sync.orderMoves = [NotebookOrderMove(
            id: id(901), notebookID: lastChild.id, beforeID: firstChild.id,
            eligibleIDs: Set(order), clock: SyncClock(counter: 3, deviceID: "b"),
            scoped: true, folderID: firstFolder.id
        )]

        let merged = LibraryReconciliation.merge(rootMove, with: childMove)
        XCTAssertEqual(merged.itemIDs(in: nil), [secondFolder.id, rootFirst.id, firstFolder.id, rootLast.id])
        XCTAssertEqual(merged.itemIDs(in: firstFolder.id), [lastChild.id, firstChild.id])
        XCTAssertEqual(merged.itemIDs(in: secondFolder.id), [otherChild.id])
        XCTAssertEqual(merged.itemOrder.firstIndex(of: archived.id), order.firstIndex(of: archived.id))
        XCTAssertEqual(LibraryReconciliation.merge(childMove, with: rootMove).itemOrder, merged.itemOrder)
        XCTAssertEqual(LibraryReconciliation.merge(merged, with: rootMove).itemOrder, merged.itemOrder)
        XCTAssertEqual(Set(merged.notebooks.map(\.id)), Set(notebooks.map(\.id)))
        for saved in merged.notebooks {
            let original = notebooks.first { $0.id == saved.id }
            XCTAssertEqual(saved.folderID, original?.folderID)
            XCTAssertEqual(saved.revisionID, original?.revisionID)
            XCTAssertEqual(saved.isArchived, original?.isArchived)
        }
    }

    func testConcurrentPDFConflictCopiesKeepEachBranchFolder() throws {
        let firstFolder = folder(500, name: "Math")
        let secondFolder = folder(501, name: "Projects")
        let base = notebook(1, folderID: firstFolder.id)
        let left = child(base, number: 11)
        var right = child(base, number: 12)
        right.folderID = secondFolder.id
        right.fieldClocks.folder = SyncClock(counter: 3, deviceID: "b")
        let folders = [firstFolder, secondFolder]
        let merged = LibraryReconciliation.merge(manifest([left], folders: folders), with: manifest([right], folders: folders))

        XCTAssertEqual(merged.notebooks.count, 2)
        XCTAssertEqual(merged.notebooks.first { $0.contentVersionID == left.contentVersionID }?.folderID, firstFolder.id)
        XCTAssertEqual(merged.notebooks.first { $0.contentVersionID == right.contentVersionID }?.folderID, secondFolder.id)
        XCTAssertEqual(merged.notebooks.filter { $0.conflictOriginID != nil }.count, 1)
        let replay = LibraryReconciliation.merge(merged, with: manifest([left, right], folders: folders))
        XCTAssertEqual(replay.notebooks, merged.notebooks)
        XCTAssertEqual(Set(replay.notebooks.map(\.revisionID)), Set([left.revisionID, right.revisionID]))
    }

    func testOfflineFolderMoveAfterNotebookDeletionRecoversMembershipOnce() throws {
        let firstFolder = folder(500, name: "Math")
        let secondFolder = folder(501, name: "Projects")
        let base = notebook(1, folderID: firstFolder.id)
        var moved = base
        moved.folderID = secondFolder.id
        moved.fieldClocks.folder = SyncClock(counter: 3, deviceID: "offline")
        let folders = [firstFolder, secondFolder]
        var deleted = manifest([], folders: folders)
        deleted.sync.tombstones = [NotebookTombstone(notebook: base, clock: SyncClock(counter: 4, deviceID: "a"))]
        let merged = LibraryReconciliation.merge(deleted, with: manifest([moved], folders: folders))
        let recovered = try XCTUnwrap(merged.notebooks.first)

        XCTAssertEqual(merged.notebooks.count, 1)
        XCTAssertNotEqual(recovered.id, base.id)
        XCTAssertEqual(recovered.recoverySourceID, base.id)
        XCTAssertEqual(recovered.folderID, secondFolder.id)
        XCTAssertEqual(recovered.fieldClocks.folder, moved.fieldClocks.folder)
        XCTAssertEqual(recovered.revisionID, base.revisionID)
        XCTAssertEqual(merged.itemIDs(in: secondFolder.id), [recovered.id])
        XCTAssertEqual(LibraryReconciliation.merge(merged, with: manifest([moved], folders: folders)).notebooks, merged.notebooks)
    }

    private func folder(_ number: Int, name: String) -> NotebookFolder {
        NotebookFolder(id: id(number), name: name)
    }

    private func notebook(_ number: Int, folderID: UUID? = nil) -> Notebook {
        Notebook(id: id(number), name: "Notebook \(number)", createdAt: Date(timeIntervalSince1970: 0),
                 modifiedAt: Date(timeIntervalSince1970: 0), revisionID: id(100 + number),
                 pages: [NotebookPage(id: id(200 + number))], folderID: folderID)
    }

    private func child(_ base: Notebook, number: Int) -> Notebook {
        var result = base
        result.revisionID = id(100 + number)
        result.contentVersionID = id(number)
        result.contentAncestors.insert(base.contentVersionID)
        result.contentHistory.append(NotebookContentVersion(
            id: result.contentVersionID, parentIDs: [base.contentVersionID],
            revisionID: result.revisionID, pages: result.pages
        ))
        return result
    }

    private func manifest(_ notebooks: [Notebook], folders: [NotebookFolder] = [], order: [UUID]? = nil) -> LibraryManifest {
        var state = LibrarySyncState()
        state.orderSeedID = "folder-sync-tests"
        state.baseOrder = order ?? (1...6).map(id) + [id(500), id(501)]
        return LibraryManifest(notebooks: notebooks, folders: folders, itemOrder: order, sync: state)
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}
