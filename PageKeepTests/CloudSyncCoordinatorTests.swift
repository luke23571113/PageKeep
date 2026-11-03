import XCTest
@testable import PageKeep

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    private var folder: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: LibraryStore!
    private var transport: TestCloudTransport!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncTests-\(UUID().uuidString)")
        suiteName = "CloudSyncTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = LibraryStore(repository: LibraryRepository(rootURL: folder.appendingPathComponent("Library")))
        transport = TestCloudTransport()
    }

    override func tearDownWithError() throws {
        transport.resumeFetch()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    func testSyncDefaultsOffAndUnavailableSetupNeverStartsTransport() async {
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport, isAvailable: false)
        XCTAssertFalse(coordinator.isEnabled)
        await coordinator.sceneBecameActive()
        await coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: CloudSyncCoordinator.enabledKey))
        XCTAssertEqual(transport.accountChecks, 0)
        XCTAssertNotNil(coordinator.errorMessage)
        coordinator.sceneBecameInactive()
    }

    func testFirstEnableBootstrapsWholeLibraryAndAcknowledgesOnlyConfirmedOperations() async throws {
        await store.load()
        transport.acknowledgesUploads = false
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        await coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertGreaterThan(store.pendingSyncCount, 0)
        XCTAssertEqual(coordinator.status, "Waiting to sync")
        let firstUpload = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(firstUpload.notebooks.count, 1)
        XCTAssertFalse(firstUpload.sync.outbox.isEmpty)

        transport.acknowledgesUploads = true
        await coordinator.refresh()
        XCTAssertEqual(store.pendingSyncCount, 0)
        XCTAssertEqual(coordinator.status, "Up to date")
        XCTAssertEqual(defaults.string(forKey: CloudSyncCoordinator.accountKey), "account-A")
        await coordinator.setEnabled(false)
        XCTAssertEqual(store.notebooks.count, 1)
    }

    func testTemporaryAccountFailurePreservesOptInAndLocalPDF() async throws {
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        let pdf = try XCTUnwrap(store.pdfURL(for: notebook))
        transport.accountError = CloudSyncError.accountUnavailable
        var currentDate = Date()
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport, now: { currentDate })
        await coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: CloudSyncCoordinator.enabledKey))
        XCTAssertEqual(coordinator.status, "Waiting to sync")
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        transport.accountError = nil
        currentDate = currentDate.addingTimeInterval(60)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.status, "Up to date")
        await coordinator.setEnabled(false)
    }

    func testDisablingDuringDownloadCannotApplyOrAcknowledgeStaleResponse() async throws {
        await store.load()
        let original = store.notebooks
        transport.suspendsFetch = true
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        let enabling = Task { await coordinator.setEnabled(true) }
        while transport.fetchContinuation == nil { await Task.yield() }
        await coordinator.setEnabled(false)
        await enabling.value
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(store.notebooks, original)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertGreaterThan(store.pendingSyncCount, 0)
        XCTAssertEqual(coordinator.status, "iCloud sync is off")
    }

    func testDifferentAccountRequiresConfirmationAndDropsOldAccountTombstones() async throws {
        await store.load()
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        await coordinator.setEnabled(true)
        let original = try XCTUnwrap(store.notebooks.first)
        let source = try XCTUnwrap(store.pdfURL(for: original))
        let prepared = try await store.repository.prepareImport(from: source)
        _ = try await store.saveNotebook(details: NotebookDetails(name: "Retained"), notebookID: nil, additions: [prepared])
        await store.repository.discardPrepared(prepared)
        try await store.deleteNotebook(original.id)
        let retainedID = try XCTUnwrap(store.notebooks.first?.id)
        transport.account = "account-B"
        let sentCount = transport.sent.count
        await coordinator.refresh()
        XCTAssertTrue(coordinator.needsAccountConfirmation)
        XCTAssertEqual(transport.sent.count, sentCount)
        XCTAssertEqual(defaults.string(forKey: CloudSyncCoordinator.accountKey), "account-A")

        await coordinator.confirmAccountChange()
        XCTAssertFalse(coordinator.needsAccountConfirmation)
        XCTAssertEqual(defaults.string(forKey: CloudSyncCoordinator.accountKey), "account-B")
        XCTAssertEqual(store.notebooks.map(\.id), [retainedID])
        let outgoing = try XCTUnwrap(transport.sent.last)
        XCTAssertTrue(outgoing.sync.tombstones.isEmpty)
        XCTAssertTrue(outgoing.sync.outbox.allSatisfy { $0.tombstone == nil })
        XCTAssertEqual(transport.resetAccounts, ["account-B"])
        await coordinator.setEnabled(false)
    }

    func testAccountSwitchDuringDownloadCannotCommitRemoteRevision() async throws {
        await store.load()
        let original = store.notebooks
        transport.changesAccountDuringFetch = true
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        await coordinator.setEnabled(true)
        XCTAssertEqual(store.notebooks, original)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(coordinator.needsAccountConfirmation)
        await coordinator.refresh()
        XCTAssertTrue(coordinator.needsAccountConfirmation)
        await coordinator.setEnabled(false)
    }

    func testDurableInboxRoundTripFoldsSnapshotHistoryBeforeReconciliation() async throws {
        await store.load()
        try await store.prepareForSync()
        let notebook = try XCTUnwrap(store.notebooks.first)
        var details = notebook.details
        details.name = "Renamed remotely"
        _ = try await store.saveNotebook(details: details, notebookID: notebook.id, additions: [])
        let snapshot = try await store.repository.syncSnapshot()
        var cache = CloudAccountCache(accountID: "account-A")
        for entry in snapshot.sync.outbox {
            cache.metadata[entry.id.uuidString] = CloudMetadataPayload(operation: entry)
        }
        cache.metadata["seed"] = CloudMetadataPayload(orderSeed: CloudOrderSeed(id: snapshot.sync.orderSeedID, notebookIDs: snapshot.sync.baseOrder))
        let reopened = try JSONDecoder().decode(CloudAccountCache.self, from: JSONEncoder().encode(cache))
        let folded = try reopened.manifest()
        XCTAssertEqual(folded.notebooks.count, 1)
        XCTAssertEqual(folded.notebooks.first?.name, "Renamed remotely")
        XCTAssertEqual(folded.notebooks.first?.pages, notebook.pages)
        XCTAssertEqual(folded.sync.logicalClock, snapshot.sync.logicalClock)
        XCTAssertTrue(folded.sync.outbox.isEmpty)
    }

    func testServerRetryDelayPreventsEarlyManualRetries() async {
        await store.load()
        var currentDate = Date()
        transport.retryMessage = "iCloud is temporarily busy"
        transport.retryAfterSeconds = 120
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport, now: { currentDate })
        await coordinator.setEnabled(true)
        let attempts = transport.sent.count
        currentDate = currentDate.addingTimeInterval(119)
        await coordinator.refresh()
        XCTAssertEqual(transport.sent.count, attempts)
        currentDate = currentDate.addingTimeInterval(2)
        transport.retryMessage = nil
        transport.retryAfterSeconds = nil
        await coordinator.refresh()
        XCTAssertEqual(transport.sent.count, attempts + 1)
        XCTAssertEqual(coordinator.status, "Up to date")
        await coordinator.setEnabled(false)
    }

    func testIncompatibleImmutableVersionsAreRejectedBeforeFolding() async throws {
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        var changed = notebook
        let version = try XCTUnwrap(notebook.contentHistory.first)
        changed.contentHistory = [NotebookContentVersion(
            id: version.id, parentIDs: version.parentIDs, revisionID: version.revisionID,
            pages: Array(version.pages.reversed())
        )]
        let first = SyncOutboxEntry(id: UUID(), notebook: notebook, tombstone: nil, move: nil)
        let second = SyncOutboxEntry(id: UUID(), notebook: changed, tombstone: nil, move: nil)
        var cache = CloudAccountCache(accountID: "account-A")
        cache.metadata["first"] = CloudMetadataPayload(operation: first)
        cache.metadata["second"] = CloudMetadataPayload(operation: second)
        XCTAssertThrowsError(try cache.manifest())
    }

    func testDisabledRemoteNotificationMakesNoAccountRequest() async {
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        let changed = await coordinator.handleRemoteNotification()
        XCTAssertFalse(changed)
        XCTAssertEqual(transport.accountChecks, 0)
    }

    func testLegacyPayloadRetriesMatchContentsButRejectChangedMembership() async throws {
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        let entry = SyncOutboxEntry(id: UUID(), notebook: notebook, tombstone: nil, move: nil)
        let legacy = CloudMetadataPayload(schemaVersion: 1, operation: entry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var operation = try XCTUnwrap(object["operation"] as? [String: Any])
        var oldNotebook = try XCTUnwrap(operation["notebook"] as? [String: Any])
        var fields = try XCTUnwrap(oldNotebook["fieldClocks"] as? [String: Any])
        fields.removeValue(forKey: "folder")
        oldNotebook["fieldClocks"] = fields
        oldNotebook.removeValue(forKey: "folderID")
        operation["notebook"] = oldNotebook
        object["operation"] = operation
        let decoded = try JSONDecoder().decode(CloudMetadataPayload.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertTrue(decoded.hasSameContents(as: CloudMetadataPayload(operation: entry)))
        XCTAssertEqual(decoded.schemaVersion, 1)

        var moved = notebook
        moved.folderID = UUID()
        let changed = SyncOutboxEntry(id: entry.id, notebook: moved, tombstone: nil, move: nil)
        XCTAssertFalse(decoded.hasSameContents(as: CloudMetadataPayload(operation: changed)))
    }

    func testFutureCachedPayloadStopsBeforeReconciliation() throws {
        var cache = CloudAccountCache(accountID: "test")
        cache.metadata["future"] = CloudMetadataPayload(schemaVersion: 3, orderSeed: CloudOrderSeed(id: UUID().uuidString, notebookIDs: []))
        XCTAssertThrowsError(try cache.manifest()) { error in
            guard case CloudSyncError.newerCloudSchema = error else { return XCTFail("Expected an app-update error") }
        }
    }

    func testFolderAndMembershipBootstrapAndSurviveDisableAndAccountReset() async throws {
        await store.load()
        let notebook = try XCTUnwrap(store.notebooks.first)
        let folderID = try await store.createFolder(name: "Classes")
        try await store.moveNotebook(notebook.id, toFolderID: folderID)
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        await coordinator.setEnabled(true)
        let outgoing = try XCTUnwrap(transport.sent.last)
        XCTAssertTrue(outgoing.sync.outbox.contains { $0.folder?.id == folderID })
        XCTAssertTrue(outgoing.sync.outbox.contains { $0.notebook?.folderID == folderID })
        var cache = CloudAccountCache(accountID: "account-A")
        for entry in outgoing.sync.outbox {
            cache.metadata[entry.id.uuidString] = CloudMetadataPayload(operation: entry)
        }
        let reopened = try JSONDecoder().decode(CloudAccountCache.self, from: JSONEncoder().encode(cache))
        let folded = try reopened.manifest()
        XCTAssertEqual(folded.folders.map(\.id), [folderID])
        XCTAssertEqual(folded.notebooks.first?.folderID, folderID)
        XCTAssertEqual(Set(folded.itemOrder), [notebook.id, folderID])

        await coordinator.setEnabled(false)
        XCTAssertEqual(store.folders.map(\.id), [folderID])
        XCTAssertEqual(store.notebooks.first?.folderID, folderID)
        transport.account = "account-B"
        await coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.needsAccountConfirmation)
        await coordinator.confirmAccountChange()
        XCTAssertEqual(store.notebooks.first?.folderID, folderID)
        XCTAssertEqual(store.folders.map(\.id), [folderID])
        let reset = try await store.repository.syncSnapshot()
        XCTAssertTrue(reset.sync.folderTombstones.isEmpty)
        await coordinator.setEnabled(false)
    }

    func testFolderOnlyRemoteNotificationReportsNewData() async throws {
        await store.load()
        let coordinator = CloudSyncCoordinator(store: store, defaults: defaults, transport: transport)
        await coordinator.setEnabled(true)
        transport.download = LibraryManifest(notebooks: [], folders: [NotebookFolder(id: UUID(), name: "Remote Classes")])
        let changed = await coordinator.handleRemoteNotification()
        XCTAssertTrue(changed)
        XCTAssertEqual(store.folders.first?.name, "Remote Classes")
        await coordinator.setEnabled(false)
    }

    func testFolderExpansionRemainsDeviceLocalAndPersists() {
        let id = UUID()
        let expansion = FolderExpansionStore(defaults: defaults)
        XCTAssertFalse(expansion.isExpanded(id))
        expansion.setExpanded(true, for: id)
        XCTAssertTrue(FolderExpansionStore(defaults: defaults).isExpanded(id))
        let otherName = suiteName + ".other"
        let other = UserDefaults(suiteName: otherName)!
        defer { other.removePersistentDomain(forName: otherName) }
        XCTAssertFalse(FolderExpansionStore(defaults: other).isExpanded(id))
        expansion.setExpanded(false, for: id)
        XCTAssertFalse(FolderExpansionStore(defaults: defaults).isExpanded(id))
    }
}

@MainActor
private final class TestCloudTransport: CloudSyncTransport {
    var onRemoteChange: (() -> Void)?
    var onProgress: ((Double?) -> Void)?
    var account = "account-A"
    var accountError: Error?
    var accountChecks = 0
    var acknowledgesUploads = true
    var suspendsFetch = false
    var changesAccountDuringFetch = false
    var fetchContinuation: CheckedContinuation<Void, Never>?
    var sent: [LibraryManifest] = []
    var resetAccounts: [String] = []
    var retryMessage: String?
    var retryAfterSeconds: Double?
    var download: LibraryManifest?

    func accountIdentifier() async throws -> String {
        accountChecks += 1
        if let accountError { throw accountError }
        return account
    }

    func start(accountID: String) async throws { }
    func stop() async { resumeFetch() }
    func resetAccountState(accountID: String) throws { resetAccounts.append(accountID) }

    func fetchChanges(existingPDFs: [UUID: URL]) async throws -> CloudSyncDownload {
        if suspendsFetch { await withCheckedContinuation { fetchContinuation = $0 } }
        if changesAccountDuringFetch { account = "account-B" }
        if let download { return CloudSyncDownload(manifest: download, pdfURLs: [:]) }
        var empty = LibraryManifest(notebooks: [])
        empty.sync.orderSeedID = "~"
        empty.sync.needsBootstrap = false
        return CloudSyncDownload(manifest: empty, pdfURLs: [:])
    }

    func sendChanges(_ manifest: LibraryManifest, pdfURLs: [UUID: URL]) async throws -> CloudSyncUpload {
        sent.append(manifest)
        return CloudSyncUpload(
            acknowledgedIDs: acknowledgesUploads ? Set(manifest.sync.outbox.map(\.id)) : [],
            retryMessage: retryMessage, retryAfterSeconds: retryAfterSeconds
        )
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}
