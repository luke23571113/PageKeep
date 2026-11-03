import XCTest
import PDFKit
@testable import PageKeep

final class LibrarySyncTests: XCTestCase {
    func testIndependentMetadataFieldsMergeWithLogicalClockAndDeviceTieBreak() {
        let base = notebook()
        var left = base
        left.name = "Math"
        left.fieldClocks.name = SyncClock(counter: 3, deviceID: "a")
        var right = base
        right.colorID = "green"
        right.fieldClocks.color = SyncClock(counter: 3, deviceID: "b")
        right.name = "Notes"
        right.fieldClocks.name = SyncClock(counter: 3, deviceID: "b")
        let result = LibraryReconciliation.merge(manifest([left]), with: manifest([right]))
        XCTAssertEqual(result.notebooks.count, 1)
        XCTAssertEqual(result.notebooks[0].name, "Notes")
        XCTAssertEqual(result.notebooks[0].colorID, "green")
        XCTAssertEqual(result.notebooks[0].revisionID, base.revisionID)
    }

    func testConcurrentPDFsConvergeAcrossThreeDevicesAndReplays() {
        let base = notebook()
        let a = child(base, number: 11)
        let b = child(base, number: 12)
        let c = child(base, number: 13)
        let ab = LibraryReconciliation.merge(manifest([a]), with: manifest([b]))
        let ba = LibraryReconciliation.merge(manifest([b]), with: manifest([a]))
        XCTAssertEqual(sorted(ab), sorted(ba))
        let abc = LibraryReconciliation.merge(ab, with: manifest([c]))
        let bc = LibraryReconciliation.merge(manifest([b]), with: manifest([c]))
        let aBC = LibraryReconciliation.merge(manifest([a]), with: bc)
        XCTAssertEqual(sorted(abc), sorted(aBC))
        XCTAssertEqual(abc.notebooks.count, 3)
        XCTAssertEqual(Set(abc.notebooks.map(\.revisionID)), Set([a.revisionID, b.revisionID, c.revisionID]))
        XCTAssertEqual(sorted(LibraryReconciliation.merge(abc, with: abc)), sorted(abc))
        XCTAssertEqual(sorted(LibraryReconciliation.merge(abc, with: manifest([a, b, c]))), sorted(abc))
        XCTAssertEqual(abc.notebooks.filter { $0.name.contains("(Conflict)") }.count, 2)
    }

    func testConflictIdentitySurvivesMetadataChangesAndDescendantReplay() throws {
        let base = notebook()
        let a = child(base, number: 11)
        let b = child(base, number: 12)
        let merged = LibraryReconciliation.merge(manifest([a]), with: manifest([b]))
        let copy = try XCTUnwrap(merged.notebooks.first { $0.contentVersionID == a.contentVersionID })
        XCTAssertNotEqual(copy.id, base.id)
        var renamed = a
        renamed.name = "Renamed"
        renamed.fieldClocks.name = SyncClock(counter: 9, deviceID: "offline")
        let metadata = LibraryReconciliation.merge(merged, with: manifest([renamed]))
        XCTAssertEqual(metadata.notebooks.count, 2)
        XCTAssertEqual(metadata.notebooks.first { $0.contentVersionID == a.contentVersionID }?.id, copy.id)
        let descendant = child(renamed, number: 14)
        let updated = LibraryReconciliation.merge(metadata, with: manifest([descendant]))
        XCTAssertEqual(updated.notebooks.count, 2)
        XCTAssertEqual(updated.notebooks.first { $0.contentVersionID == descendant.contentVersionID }?.id, copy.id)
        XCTAssertEqual(sorted(LibraryReconciliation.merge(updated, with: merged)), sorted(updated))
    }

    func testNestedConcurrentBranchesConvergeWithoutLosingPDFs() {
        let base = notebook()
        let a = child(base, number: 11)
        let b = child(base, number: 12)
        let a1 = child(a, number: 13)
        let a2 = child(a, number: 14)
        let first = LibraryReconciliation.merge(
            LibraryReconciliation.merge(manifest([a1]), with: manifest([b])), with: manifest([a2])
        )
        let second = LibraryReconciliation.merge(
            manifest([a1]), with: LibraryReconciliation.merge(manifest([a2]), with: manifest([b]))
        )
        XCTAssertEqual(sorted(first), sorted(second))
        XCTAssertEqual(Set(first.notebooks.map(\.contentVersionID)), Set([a1.contentVersionID, a2.contentVersionID, b.contentVersionID]))
    }

    func testDeletionKeepsUnchangedCopyDeletedAndRecoversActualEditsOnce() throws {
        let base = notebook()
        var deleted = manifest([])
        deleted.sync.tombstones = [NotebookTombstone(notebook: base, clock: SyncClock(counter: 4, deviceID: "a"))]
        XCTAssertTrue(LibraryReconciliation.merge(manifest([base]), with: deleted).notebooks.isEmpty)
        let edited = child(base, number: 11)
        let recovered = LibraryReconciliation.merge(manifest([edited]), with: deleted)
        let copy = try XCTUnwrap(recovered.notebooks.first)
        XCTAssertNotEqual(copy.id, base.id)
        XCTAssertTrue(copy.name.hasSuffix("(Recovered)"))
        XCTAssertEqual(recovered.sync.tombstones.map(\.id), [base.id])
        let replay = LibraryReconciliation.merge(recovered, with: manifest([edited]))
        XCTAssertEqual(sorted(replay), sorted(recovered))
        let later = child(edited, number: 12)
        let updated = LibraryReconciliation.merge(recovered, with: manifest([later]))
        XCTAssertEqual(updated.notebooks.count, 1)
        XCTAssertEqual(updated.notebooks[0].id, copy.id)
        XCTAssertEqual(updated.notebooks[0].contentVersionID, later.contentVersionID)
    }

    func testDeletingConflictCopyDoesNotDeleteOtherBranch() throws {
        let base = notebook()
        let merged = LibraryReconciliation.merge(manifest([child(base, number: 11)]), with: manifest([child(base, number: 12)]))
        let copy = try XCTUnwrap(merged.notebooks.first { $0.id != base.id })
        var deleted = merged
        deleted.notebooks.removeAll { $0.id == copy.id }
        deleted.sync.tombstones.append(NotebookTombstone(notebook: copy, clock: SyncClock(counter: 4, deviceID: "a")))
        let replay = LibraryReconciliation.merge(deleted, with: merged)
        XCTAssertEqual(replay.notebooks.count, 1)
        XCTAssertEqual(replay.notebooks[0].id, base.id)
        XCTAssertEqual(replay.notebooks[0].contentVersionID, id(12))
        let rawReplay = LibraryReconciliation.merge(deleted, with: manifest([child(base, number: 11)]))
        XCTAssertEqual(sorted(rawReplay), sorted(replay))
        let offlineEdit = child(child(base, number: 11), number: 13)
        let recovered = LibraryReconciliation.merge(deleted, with: manifest([offlineEdit]))
        XCTAssertEqual(recovered.notebooks.count, 2)
        XCTAssertTrue(recovered.notebooks.contains { $0.contentVersionID == offlineEdit.contentVersionID && $0.recoverySourceID == copy.id })
    }

    func testConcurrentDeletionsRetainAllExplicitlyDeletedVersionsAcrossReplays() throws {
        let base = notebook()
        let branches = [child(base, number: 11), child(base, number: 12), child(base, number: 13)]
        let deletions = branches.enumerated().map { index, branch -> LibraryManifest in
            var deleted = manifest([])
            deleted.sync.tombstones = [NotebookTombstone(
                notebook: branch, clock: SyncClock(counter: 4, deviceID: String(index))
            )]
            return deleted
        }
        let snapshots = manifest([base] + branches)
        let deliveryOrders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in deliveryOrders {
            var state = snapshots
            for index in order { state = LibraryReconciliation.merge(state, with: deletions[index]) }
            state = LibraryReconciliation.merge(state, with: snapshots)
            XCTAssertTrue(state.notebooks.isEmpty)
            let deleted = try XCTUnwrap(state.sync.tombstones.first)
            XCTAssertTrue(Set(branches.map(\.contentVersionID)).isSubset(of: Set(deleted.notebook.contentHistory.map(\.id))))
            XCTAssertEqual(deleted.clock, deletions[2].sync.tombstones[0].clock)
            XCTAssertNoThrow(try LibraryFiles(rootURL: temporaryRoot()).validate(state))
        }
    }

    func testConcurrentDeletionsAlsoCoverIndependentlyDeletedMetadataEdits() {
        let base = notebook()
        var renamed = base
        renamed.name = "Renamed"
        renamed.fieldClocks.name = SyncClock(counter: 2, deviceID: "a")
        var recolored = base
        recolored.colorID = "green"
        recolored.fieldClocks.color = SyncClock(counter: 2, deviceID: "b")
        var deleted = manifest([])
        deleted.sync.tombstones = [
            NotebookTombstone(notebook: renamed, clock: SyncClock(counter: 3, deviceID: "a")),
            NotebookTombstone(notebook: recolored, clock: SyncClock(counter: 3, deviceID: "b"))
        ]
        let state = LibraryReconciliation.merge(manifest([base, renamed, recolored]), with: deleted)
        XCTAssertTrue(state.notebooks.isEmpty)
    }

    func testRecoveredIdentitySurvivesAdditionalConcurrentDeletionRecords() throws {
        let base = notebook()
        let edited = child(base, number: 11)
        var firstDeletion = manifest([])
        firstDeletion.sync.tombstones = [NotebookTombstone(notebook: base, clock: SyncClock(counter: 3, deviceID: "a"))]
        let recovered = LibraryReconciliation.merge(manifest([edited]), with: firstDeletion)
        let copy = try XCTUnwrap(recovered.notebooks.first)
        var secondDeletion = manifest([])
        secondDeletion.sync.tombstones = [NotebookTombstone(notebook: base, clock: SyncClock(counter: 4, deviceID: "b"))]
        let updated = LibraryReconciliation.merge(recovered, with: secondDeletion)
        let replay = LibraryReconciliation.merge(updated, with: manifest([edited, copy]))
        XCTAssertEqual(replay.notebooks.count, 1)
        XCTAssertEqual(replay.notebooks[0].id, copy.id)
        XCTAssertEqual(replay.notebooks[0].contentVersionID, edited.contentVersionID)
    }

    func testDownloadedConflictIsUploadedBeforeDeletingOriginalAndSurvivesFreshCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let base = try XCTUnwrap(initial.manifest.notebooks.first)
        let source = try XCTUnwrap(repository.pdfURL(for: base))
        _ = try await repository.acknowledgeSyncEntries(Set(initial.manifest.sync.outbox.map(\.id)))
        let a = child(base, number: 11)
        let b = child(base, number: 12)
        var cache = CloudAccountCache(accountID: "test")
        for branch in [a, b] {
            let operation = SyncOutboxEntry(id: UUID(), notebook: branch, tombstone: nil, move: nil)
            cache.metadata[operation.id.uuidString] = CloudMetadataPayload(operation: operation)
        }
        let remote = try cache.manifest()
        let files = LibraryFiles(rootURL: root)
        XCTAssertNoThrow(try files.validate(remote))
        XCTAssertNoThrow(try files.validateCompatibleVersions([initial.manifest, remote]))
        XCTAssertNoThrow(try files.validate(LibraryReconciliation.merge(initial.manifest, with: remote)))
        let downloaded = try await repository.reconcile(
            with: remote, downloadedPDFs: [try XCTUnwrap(a.revisionID): source, try XCTUnwrap(b.revisionID): source]
        )
        let copy = try XCTUnwrap(downloaded.manifest.notebooks.first { $0.id != base.id })
        XCTAssertTrue(downloaded.manifest.sync.outbox.contains { $0.notebook?.id == copy.id })
        let deleted = try await repository.deleteNotebook(base.id)
        for operation in deleted.manifest.sync.outbox {
            cache.metadata[operation.id.uuidString] = CloudMetadataPayload(operation: operation)
        }
        let fresh = try cache.manifest()
        XCTAssertEqual(fresh.notebooks.count, 1)
        XCTAssertEqual(fresh.notebooks.first?.id, copy.id)
        XCTAssertEqual(fresh.notebooks.first?.contentVersionID, copy.contentVersionID)
        let incremental = LibraryReconciliation.merge(downloaded.manifest, with: fresh)
        XCTAssertEqual(sorted(incremental), sorted(fresh))
    }

    func testStableIDMovesPreserveArchiveSlotsAndUnrelatedIncomingNotebook() {
        let a = notebook(number: 1)
        var archive = notebook(number: 2)
        archive.isArchived = true
        let b = notebook(number: 3)
        let unrelated = notebook(number: 4)
        var left = manifest([a, archive, b, unrelated])
        left.sync.baseOrder = [a.id, archive.id, b.id, unrelated.id]
        left.sync.orderMoves = [NotebookOrderMove(
            id: id(99), notebookID: b.id, beforeID: a.id, eligibleIDs: [a.id, b.id],
            clock: SyncClock(counter: 3, deviceID: "a")
        )]
        let result = LibraryReconciliation.merge(left, with: left)
        XCTAssertEqual(result.notebooks.map(\.id), [b.id, archive.id, a.id, unrelated.id])
    }

    func testInsertionCanPrecedeArchiveWithoutChangingActiveReorderSemantics() {
        let a = notebook(number: 1)
        var archive = notebook(number: 2)
        archive.isArchived = true
        var state = manifest([archive, a])
        state.sync.baseOrder = [archive.id, a.id]
        state.sync.orderMoves = [NotebookOrderMove(
            id: id(99), notebookID: a.id, beforeID: archive.id, eligibleIDs: [a.id, archive.id],
            clock: SyncClock(counter: 3, deviceID: "a"), includesArchived: true
        )]
        let result = LibraryReconciliation.merge(state, with: state)
        XCTAssertEqual(result.notebooks.map(\.id), [a.id, archive.id])
    }

    func testUnrelatedSameNamesResolveDeterministicallyWithoutRepeatedSuffixes() {
        var a = notebook(number: 1)
        var b = notebook(number: 2)
        a.name = "Math"
        b.name = "Math"
        let merged = LibraryReconciliation.merge(manifest([a]), with: manifest([b]))
        XCTAssertEqual(Set(merged.notebooks.map(\.id)), [a.id, b.id])
        XCTAssertEqual(Set(merged.notebooks.map(\.name)), ["Math", "Math (1)"])
        let replay = LibraryReconciliation.merge(merged, with: manifest([a, b]))
        XCTAssertEqual(sorted(replay), sorted(merged))
        XCTAssertEqual(sorted(LibraryReconciliation.merge(manifest([b]), with: manifest([a]))), sorted(merged))
    }

    func testPendingMetadataConflictKeepsLosingValueInDismissibleNotice() {
        var a = notebook()
        a.name = "Local title"
        a.fieldClocks.name = SyncClock(counter: 4, deviceID: "a")
        var b = notebook()
        b.name = "Remote title"
        b.fieldClocks.name = SyncClock(counter: 4, deviceID: "b")
        var local = manifest([a])
        local.sync.outbox = [SyncOutboxEntry(id: id(80), notebook: a, tombstone: nil, move: nil, clock: a.fieldClocks.name)]
        let merged = LibraryReconciliation.merge(local, with: manifest([b]))
        let notice = merged.sync.notices.first { $0.kind == .metadataConflict }
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.details?.contains("Local title") == true)
        var dismissed = merged
        if let notice { dismissed.sync.dismissedNoticeIDs.insert(notice.id) }
        dismissed.sync.notices = []
        XCTAssertTrue(LibraryReconciliation.merge(dismissed, with: manifest([b])).sync.notices.isEmpty)
    }

    func testMalformedImmutableHistoriesAndReusedPDFPageIDsAreRejected() throws {
        let base = notebook()
        let edited = child(base, number: 11)
        let files = LibraryFiles(rootURL: temporaryRoot())
        var multipleParents = edited
        multipleParents.contentHistory[multipleParents.contentHistory.count - 1] = NotebookContentVersion(
            id: edited.contentVersionID, parentIDs: [base.contentVersionID, id(99)],
            revisionID: edited.revisionID, pages: edited.pages
        )
        XCTAssertThrowsError(try files.validate(manifest([multipleParents])))
        var reusedVersion = base
        reusedVersion.pages = [NotebookPage(id: id(999))]
        reusedVersion.contentHistory = [NotebookContentVersion(id: base.contentVersionID, parentIDs: [], revisionID: base.revisionID, pages: reusedVersion.pages)]
        XCTAssertThrowsError(try files.validateCompatibleVersions([manifest([base]), manifest([reusedVersion])]))
        var reusedPDF = notebook(number: 2)
        reusedPDF.revisionID = base.revisionID
        reusedPDF.contentHistory = [NotebookContentVersion(id: reusedPDF.contentVersionID, parentIDs: [], revisionID: base.revisionID, pages: reusedPDF.pages)]
        XCTAssertThrowsError(try files.validateCompatibleVersions([manifest([base]), manifest([reusedPDF])]))
        var cycle = edited
        cycle.contentHistory[0] = NotebookContentVersion(id: base.contentVersionID, parentIDs: [edited.contentVersionID], revisionID: base.revisionID, pages: base.pages)
        XCTAssertThrowsError(try files.validate(manifest([cycle])))
    }

    func testRepositoryCommitsContentVersionAndOutboxAtomicallyAndKeepsEmptyAncestry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let original = try XCTUnwrap(initial.manifest.notebooks.first)
        let rotated = try await repository.rotatePages(in: original.id, ids: [original.pages[0].id])
        let newer = try XCTUnwrap(rotated.manifest.notebooks.first)
        XCTAssertNotEqual(newer.contentVersionID, original.contentVersionID)
        XCTAssertEqual(newer.pages, original.pages)
        XCTAssertTrue(newer.contentAncestors.contains(original.contentVersionID))
        XCTAssertTrue(rotated.manifest.sync.outbox.contains { $0.notebook == newer })
        let emptied = try await repository.deletePages(in: original.id, ids: Set(newer.pages.map(\.id)))
        let empty = try XCTUnwrap(emptied.manifest.notebooks.first)
        XCTAssertNil(empty.revisionID)
        XCTAssertNotEqual(empty.contentVersionID, newer.contentVersionID)
        XCTAssertTrue(empty.contentAncestors.contains(newer.contentVersionID))
        let reopened = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(reopened.manifest.notebooks, emptied.manifest.notebooks)
        XCTAssertEqual(reopened.manifest.sync.outbox, emptied.manifest.sync.outbox)
    }

    func testFailedManifestSaveDoesNotAdvanceQueueOrLogicalClock() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let before = try await repository.load()
        let failing = LibraryRepository(rootURL: root) { checkpoint in
            if case .beforeManifestCommit = checkpoint { throw SyncTestFailure.injected }
        }
        _ = try await failing.load()
        let sample = try XCTUnwrap(before.manifest.notebooks.first)
        do { _ = try await failing.deleteNotebook(sample.id); XCTFail("Expected injected failure") }
        catch SyncTestFailure.injected { }
        let after = try await LibraryRepository(rootURL: root).load()
        XCTAssertEqual(after.manifest.notebooks, before.manifest.notebooks)
        XCTAssertEqual(after.manifest.sync.outbox, before.manifest.sync.outbox)
        XCTAssertEqual(after.manifest.sync.logicalClock, before.manifest.sync.logicalClock)
        XCTAssertTrue(after.manifest.sync.tombstones.isEmpty)
    }

    func testDeletionAndAcknowledgementPersistAcrossRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = try XCTUnwrap(initial.manifest.notebooks.first)
        let deleted = try await repository.deleteNotebook(sample.id)
        XCTAssertEqual(deleted.manifest.sync.tombstones.map(\.id), [sample.id])
        let ids = Set(deleted.manifest.sync.outbox.map(\.id))
        _ = try await repository.acknowledgeSyncEntries(ids)
        let reloaded = try await LibraryRepository(rootURL: root).load()
        XCTAssertTrue(reloaded.manifest.sync.outbox.isEmpty)
        XCTAssertEqual(reloaded.manifest.sync.tombstones.map(\.id), [sample.id])
        XCTAssertTrue(reloaded.manifest.notebooks.isEmpty)
    }

    func testRemoteInvalidPDFCannotReplaceCompleteSavedRevision() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = try XCTUnwrap(initial.manifest.notebooks.first)
        let newer = child(sample, number: 40)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        do { _ = try await repository.reconcile(with: manifest([newer]), downloadedPDFs: [:]); XCTFail("Expected missing download") }
        catch LibraryError.missingPDF { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded.manifest.notebooks, initial.manifest.notebooks)
    }

    func testV2MigrationBootstrapsAllNotebooksWithoutChangingPDFOrRawManifest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryFiles(rootURL: root).encode(initial.manifest)) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "sync")
        var rows = try XCTUnwrap(object["notebooks"] as? [[String: Any]])
        for index in rows.indices {
            for field in ["contentVersionID", "contentHistory", "contentAncestors", "fieldClocks", "conflictOriginID"] { rows[index].removeValue(forKey: field) }
        }
        object["notebooks"] = rows
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)
        let url = root.appendingPathComponent("manifest.json")
        try legacyBytes.write(to: url)
        let migrated = try await repository.load()
        XCTAssertEqual(migrated.manifest.schemaVersion, 4)
        XCTAssertEqual(migrated.manifest.notebooks[0].revisionID, initial.manifest.notebooks[0].revisionID)
        XCTAssertEqual(try Data(contentsOf: url), legacyBytes)
        let prepared = try await repository.prepareForSync()
        XCTAssertTrue(prepared.manifest.sync.outbox.contains { $0.notebook?.id == initial.manifest.notebooks[0].id })
        XCTAssertFalse(prepared.manifest.sync.needsBootstrap)
        let again = try await repository.prepareForSync()
        XCTAssertEqual(again.manifest.sync.outbox, prepared.manifest.sync.outbox)
    }

    func testAccountResetKeepsPDFsAndDropsPreviousAccountDeletionsAndQueue() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let sample = try XCTUnwrap(initial.manifest.notebooks.first)
        let reset = try await repository.resetSyncForNewAccount()
        XCTAssertEqual(reset.manifest.notebooks[0].revisionID, sample.revisionID)
        XCTAssertNotEqual(reset.manifest.sync.deviceID, initial.manifest.sync.deviceID)
        XCTAssertTrue(Set(reset.manifest.sync.outbox.map(\.id)).isDisjoint(with: initial.manifest.sync.outbox.map(\.id)))
        XCTAssertTrue(reset.manifest.sync.tombstones.isEmpty)
        XCTAssertEqual(reset.manifest.notebooks[0].contentHistory.count, 1)
        XCTAssertTrue(reset.manifest.notebooks[0].contentAncestors.isEmpty)
    }

    func testAccountResetMakesRecoveredNotebookIndependentOfPreviousAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let initial = try await repository.load()
        let original = try XCTUnwrap(initial.manifest.notebooks.first)
        _ = try await repository.rotatePages(in: original.id, ids: [original.pages[0].id])
        var deleted = manifest([])
        deleted.sync.tombstones = [NotebookTombstone(notebook: original, clock: SyncClock(counter: 10, deviceID: "other"))]
        let recovered = try await repository.reconcile(with: deleted, downloadedPDFs: [:])
        let copy = try XCTUnwrap(recovered.manifest.notebooks.first)
        XCTAssertEqual(copy.recoverySourceID, original.id)

        let reset = try await repository.resetSyncForNewAccount()
        let retained = try XCTUnwrap(reset.manifest.notebooks.first)
        XCTAssertNil(retained.recoverySourceID)
        XCTAssertEqual(retained.id, copy.id)
        XCTAssertEqual(retained.name, copy.name)
        XCTAssertEqual(retained.revisionID, copy.revisionID)
        let replayed = LibraryReconciliation.merge(reset.manifest, with: manifest([]))
        XCTAssertEqual(replayed.notebooks.first?.name, copy.name)
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func notebook(number: Int = 1) -> Notebook {
        Notebook(id: id(number), name: "Notebook \(number)", createdAt: Date(timeIntervalSince1970: 0),
                 modifiedAt: Date(timeIntervalSince1970: 0), revisionID: id(100 + number), pages: [NotebookPage(id: id(200 + number))])
    }

    private func child(_ base: Notebook, number: Int) -> Notebook {
        var result = base
        result.revisionID = id(100 + number)
        result.contentVersionID = id(number)
        result.contentAncestors.insert(base.contentVersionID)
        result.contentHistory.append(NotebookContentVersion(id: id(number), parentIDs: [base.contentVersionID], revisionID: result.revisionID, pages: result.pages))
        return result
    }

    private func manifest(_ notebooks: [Notebook]) -> LibraryManifest {
        var state = LibrarySyncState()
        state.orderSeedID = "seed"
        state.baseOrder = [id(1), id(2), id(3), id(4)]
        return LibraryManifest(notebooks: notebooks, sync: state)
    }

    private func sorted(_ manifest: LibraryManifest) -> [Notebook] {
        manifest.notebooks.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PageKeepSync-\(UUID().uuidString)")
    }
}

private enum SyncTestFailure: Error { case injected }
