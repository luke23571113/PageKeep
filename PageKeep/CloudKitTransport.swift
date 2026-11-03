import CloudKit
import CryptoKit
import Foundation

struct CloudOrderSeed: Codable, Equatable {
    let id: String
    let notebookIDs: [UUID]
}

struct CloudMetadataPayload: Codable, Equatable {
    var schemaVersion = 2
    var operation: SyncOutboxEntry?
    var orderSeed: CloudOrderSeed?

    func validate() throws {
        guard (1...2).contains(schemaVersion) else { throw CloudSyncError.newerCloudSchema }
        guard (operation != nil) != (orderSeed != nil) else { throw CloudSyncError.invalidCloudRecord }
    }

    // An old operation keeps its identity when only the envelope version changes.
    func hasSameContents(as other: CloudMetadataPayload) -> Bool {
        operation == other.operation && orderSeed == other.orderSeed
    }
}

struct CloudAccountCache: Codable {
    let accountID: String
    var metadata: [String: CloudMetadataPayload] = [:]
    var revisionDigests: [String: String] = [:]
    var engineState: CKSyncEngine.State.Serialization?

    func manifest() throws -> LibraryManifest {
        for payload in metadata.values { try payload.validate() }
        let operations = metadata.values.compactMap(\.operation)
        var remote = LibraryManifest(notebooks: operations.compactMap(\.notebook), folders: operations.compactMap(\.folder))
        remote.itemOrder = []
        remote.sync.needsBootstrap = false
        remote.sync.orderSeedID = "~"
        remote.sync.baseOrder = []
        if let seed = metadata.values.compactMap(\.orderSeed).min(by: { $0.id < $1.id }) {
            remote.sync.orderSeedID = seed.id
            remote.sync.baseOrder = seed.notebookIDs
        }
        remote.sync.tombstones = operations.compactMap(\.tombstone)
        remote.sync.folderTombstones = operations.compactMap(\.folderTombstone)
        remote.sync.orderMoves = operations.compactMap(\.move)
        remote.sync.logicalClock = operations.map { operation in
            let fields = operation.notebook?.fieldClocks
            return [operation.clock.counter, operation.tombstone?.clock.counter ?? 0,
                    operation.move?.clock.counter ?? 0, fields?.name.counter ?? 0,
                    fields?.symbol.counter ?? 0, fields?.color.counter ?? 0, fields?.archived.counter ?? 0,
                    fields?.folder.counter ?? 0, operation.folder?.nameClock.counter ?? 0,
                    operation.folderTombstone?.clock.counter ?? 0].max() ?? 0
        }.max() ?? 0
        var empty = LibraryManifest(notebooks: [])
        empty.sync.orderSeedID = "~"
        let files = LibraryFiles(rootURL: URL(fileURLWithPath: "/"))
        for operation in operations {
            var single = LibraryManifest(notebooks: [])
            single.sync.outbox = [operation]
            single.sync.tombstones = operation.tombstone.map { [$0] } ?? []
            single.sync.folderTombstones = operation.folderTombstone.map { [$0] } ?? []
            try files.validate(single)
        }
        try files.validateCompatibleVersions([remote])
        // Fold operation snapshots into complete branches before touching the library.
        return LibraryReconciliation.merge(empty, with: remote)
    }
}

@MainActor
final class CloudKitTransport: CloudSyncTransport, CKSyncEngineDelegate {
    var onRemoteChange: (() -> Void)?
    var onProgress: ((Double?) -> Void)?
    private let rootURL: URL
    private let containerIdentifier: String?
    private lazy var container: CKContainer = {
        if let containerIdentifier { return CKContainer(identifier: containerIdentifier) }
        return CKContainer.default()
    }()
    private let metadataZone = CKRecordZone.ID(zoneName: "PageKeepMetadata")
    private let assetZone = CKRecordZone.ID(zoneName: "PageKeepPDFRevisions")
    private var engine: CKSyncEngine?
    private var accountID: String?
    private var generation = UUID()
    private var cache: CloudAccountCache?
    private var pendingSerialization: CKSyncEngine.State.Serialization?
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]
    private var confirmedRecords = Set<CKRecord.ID>()
    private var conflictedRecords = Set<CKRecord.ID>()
    private var sessionError: Error?
    private var operations: [UUID: CKOperation] = [:]

    init(rootURL: URL, containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "PageKeepCloudKitContainerIdentifier") as? String) {
        self.rootURL = rootURL
        self.containerIdentifier = containerIdentifier
    }

    func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncError.accountUnavailable }
        return try await container.userRecordID().recordName
    }

    func start(accountID: String) async throws {
        if self.accountID == accountID, engine != nil { return }
        await stop()
        let token = generation
        guard try await accountIdentifier() == accountID else { throw CloudSyncError.accountChanged }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        self.accountID = accountID
        let url = cacheURL(for: accountID)
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(CloudAccountCache.self, from: Data(contentsOf: url))
            guard saved.accountID == accountID else { throw CloudSyncError.invalidCloudRecord }
            cache = saved
        } else {
            cache = CloudAccountCache(accountID: accountID)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: cache?.engineState, delegate: self
        )
        // Foreground refreshes keep account validation ahead of every transfer.
        configuration.automaticallySync = false
        let created = CKSyncEngine(configuration)
        engine = created
        if cache?.engineState == nil {
            try await validateSession(account: accountID, token: token)
            created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: metadataZone))])
            try await created.sendChanges(.init(scope: .zoneIDs([metadataZone])))
            if let sessionError { throw sessionError }
        }
    }

    func stop() async {
        generation = UUID()
        let previous = engine
        engine = nil
        accountID = nil
        for operation in operations.values { operation.cancel() }
        operations.removeAll()
        pendingRecords.removeAll()
        confirmedRecords.removeAll()
        conflictedRecords.removeAll()
        pendingSerialization = nil
        sessionError = nil
        cache = nil
        await previous?.cancelOperations()
    }

    func resetAccountState(accountID: String) throws {
        let folder = accountFolder(for: accountID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func fetchChanges(existingPDFs: [UUID: URL]) async throws -> CloudSyncDownload {
        let (engine, account, token) = try session()
        try await validateSession(account: account, token: token)
        sessionError = nil
        try await engine.fetchChanges(.init(scope: .zoneIDs([metadataZone])))
        try checkSession(token)
        if let sessionError { throw sessionError }
        // Inbound records are already on disk; only now advance the change checkpoint.
        guard let manifest = try cache?.manifest() else { throw CloudSyncError.invalidCloudRecord }
        try commitCheckpoint()
        var pdfURLs: [UUID: URL] = [:]
        let notebooks = manifest.notebooks.filter { $0.revisionID != nil }
        for (index, notebook) in notebooks.enumerated() {
            try await validateSession(account: account, token: token)
            guard let revision = notebook.revisionID else { continue }
            if let existing = existingPDFs[revision], FileManager.default.fileExists(atPath: existing.path) {
                pdfURLs[revision] = existing
            } else {
                pdfURLs[revision] = try await downloadPDF(for: notebook, account: account, token: token)
            }
            try checkSession(token)
            onProgress?(Double(index + 1) / Double(max(notebooks.count, 1)))
        }
        return CloudSyncDownload(manifest: manifest, pdfURLs: pdfURLs)
    }

    func sendChanges(_ manifest: LibraryManifest, pdfURLs: [UUID: URL]) async throws -> CloudSyncUpload {
        let (engine, account, token) = try session()
        try await validateSession(account: account, token: token)
        sessionError = nil
        confirmedRecords.removeAll()
        conflictedRecords.removeAll()
        let unsent = try manifest.sync.outbox.filter { entry in
            let id = CKRecord.ID(recordName: "operation-\(entry.id.uuidString)", zoneID: metadataZone)
            guard let saved = cache?.metadata[id.recordName] else { return true }
            try saved.validate()
            guard saved.hasSameContents(as: CloudMetadataPayload(operation: entry)) else { throw CloudSyncError.immutableRecordChanged }
            confirmedRecords.insert(id)
            return false
        }
        let replayed = engine.state.pendingRecordZoneChanges.filter { change in
            guard case .saveRecord(let id) = change else { return false }
            return cache?.metadata[id.recordName] != nil
        }
        engine.state.remove(pendingRecordZoneChanges: replayed)
        var uploaded = Set<UUID>()
        if unsent.contains(where: { $0.notebook?.revisionID != nil }) {
            var assetZoneReady = true
            do { try await saveAssetZone(token: token) }
            catch is CancellationError { throw CancellationError() }
            catch { try checkSession(token); assetZoneReady = false; sessionError = error }
            let notebooks = unsent.compactMap(\.notebook)
            var attempted = Set<UUID>()
            for (index, notebook) in notebooks.enumerated() {
                guard assetZoneReady, let revision = notebook.revisionID, attempted.insert(revision).inserted else { continue }
                do {
                    try await validateSession(account: account, token: token)
                    guard let url = pdfURLs[revision] else { throw CloudSyncError.assetUnavailable }
                    try await uploadPDF(at: url, notebook: notebook, token: token)
                    uploaded.insert(revision)
                } catch is CancellationError { throw CancellationError() }
                catch { try checkSession(token); sessionError = error }
                try checkSession(token)
                onProgress?(Double(index + 1) / Double(max(notebooks.count, 1)))
            }
        }
        try await validateSession(account: account, token: token)
        pendingRecords.removeAll()
        for entry in unsent {
            if let revision = entry.notebook?.revisionID, !uploaded.contains(revision) { continue }
            let id = CKRecord.ID(recordName: "operation-\(entry.id.uuidString)", zoneID: metadataZone)
            pendingRecords[id] = try record(id: id, payload: CloudMetadataPayload(operation: entry))
        }
        let seed = CloudOrderSeed(id: manifest.sync.orderSeedID, notebookIDs: manifest.sync.baseOrder)
        let seedID = CKRecord.ID(recordName: "seed-\(seed.id)", zoneID: metadataZone)
        let seedPayload = CloudMetadataPayload(orderSeed: seed)
        if let saved = cache?.metadata[seedID.recordName] {
            try saved.validate()
            guard saved.hasSameContents(as: seedPayload) else { throw CloudSyncError.immutableRecordChanged }
        } else {
            pendingRecords[seedID] = try record(id: seedID, payload: seedPayload)
        }
        if pendingRecords.isEmpty {
            return CloudSyncUpload(
                acknowledgedIDs: acknowledgedIDs(in: manifest), retryMessage: sessionError?.localizedDescription,
                retryAfterSeconds: (sessionError as? CKError)?.retryAfterSeconds
            )
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: metadataZone))])
        engine.state.add(pendingRecordZoneChanges: pendingRecords.keys.map { .saveRecord($0) })
        var retryMessage: String?
        var retryAfterSeconds: Double?
        do { try await engine.sendChanges(.init(scope: .zoneIDs([metadataZone]))) }
        catch {
            retryMessage = error.localizedDescription
            retryAfterSeconds = (error as? CKError)?.retryAfterSeconds
        }
        try checkSession(token)
        for id in conflictedRecords {
            do {
                try await validateSession(account: account, token: token)
                let server = try await fetchRecord(id, token: token)
                guard let expected = pendingRecords[id], try payload(in: server).hasSameContents(as: payload(in: expected)) else {
                    throw CloudSyncError.immutableRecordChanged
                }
                try cacheRecord(server)
                confirmedRecords.insert(id)
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            } catch {
                try checkSession(token)
                sessionError = error
            }
        }
        try checkSession(token)
        // Successful immutable records remain safe to acknowledge after a partial failure.
        if let sessionError {
            retryMessage = sessionError.localizedDescription
            retryAfterSeconds = max(retryAfterSeconds ?? 0, (sessionError as? CKError)?.retryAfterSeconds ?? 0)
        }
        if sessionError == nil, Set(pendingRecords.keys).isSubset(of: confirmedRecords) { retryMessage = nil }
        if sessionError == nil { try commitCheckpoint() }
        else { try persistCache() }
        return CloudSyncUpload(acknowledgedIDs: acknowledgedIDs(in: manifest), retryMessage: retryMessage, retryAfterSeconds: retryAfterSeconds)
    }

    private func acknowledgedIDs(in manifest: LibraryManifest) -> Set<UUID> {
        Set(manifest.sync.outbox.compactMap { entry -> UUID? in
            let id = CKRecord.ID(recordName: "operation-\(entry.id.uuidString)", zoneID: metadataZone)
            return confirmedRecords.contains(id) ? entry.id : nil
        })
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await receiveAfterAccountCheck(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(context, engine: syncEngine)
    }

    nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        await fetchOptions(engine: syncEngine)
    }

    private func fetchOptions(engine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard self.engine === engine, let accountID else { return .init(scope: .zoneIDs([])) }
        do {
            try await validateSession(account: accountID, token: generation)
            return .init(scope: .zoneIDs([metadataZone]))
        } catch {
            if self.engine === engine { sessionError = error }
            return .init(scope: .zoneIDs([]))
        }
    }

    private func receiveAfterAccountCheck(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) async {
        guard self.engine === engine, let accountID else { return }
        if case .accountChange = event {
            receive(event, from: engine)
            return
        }
        let token = generation
        do { try await validateSession(account: accountID, token: token) }
        catch {
            guard self.engine === engine, generation == token else { return }
            sessionError = error
            onRemoteChange?()
            return
        }
        receive(event, from: engine)
    }

    private func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard self.engine === engine, let accountID else { return nil }
        let token = generation
        do { try await validateSession(account: accountID, token: token) }
        catch {
            if self.engine === engine { sessionError = error }
            return nil
        }
        guard self.engine === engine else { return nil }
        let ids = engine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            guard context.options.scope.contains(change), case .saveRecord(let id) = change else { return nil }
            return id
        }
        let records = ids.compactMap { pendingRecords[$0] }
        guard !records.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: Array(records.prefix(200)))
    }

    private func receive(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) {
        guard self.engine === engine, accountID != nil else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                pendingSerialization = update.stateSerialization
            case .accountChange(let change):
                switch change.changeType {
                case .signIn(let user) where user.recordName == accountID: break
                default:
                    generation = UUID()
                    self.engine = nil
                    for operation in operations.values { operation.cancel() }
                    Task { await engine.cancelOperations() }
                    onRemoteChange?()
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications { try cacheRecord(modification.record) }
                if !changes.deletions.isEmpty { sessionError = CloudSyncError.cloudDataRemoved }
                try persistCache()
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == metadataZone || $0.zoneID == assetZone }) {
                    sessionError = CloudSyncError.cloudDataRemoved
                }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    guard let expected = pendingRecords[record.recordID],
                          try payload(in: record).hasSameContents(as: payload(in: expected)) else { continue }
                    confirmedRecords.insert(record.recordID)
                    try cacheRecord(record)
                }
                for failure in changes.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged {
                        conflictedRecords.insert(failure.record.recordID)
                        // Refetch the full server asset after this engine batch finishes.
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    } else {
                        sessionError = failure.error
                    }
                }
                try persistCache()
            case .sentDatabaseChanges(let changes):
                if let failure = changes.failedZoneSaves.first { sessionError = failure.error }
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error { sessionError = error }
            default: break
            }
        } catch { sessionError = error }
    }

    private func record(id: CKRecord.ID, payload: CloudMetadataPayload) throws -> CKRecord {
        let record = CKRecord(recordType: "PageKeepOperation", recordID: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let accountID else { throw CancellationError() }
        let folder = accountFolder(for: accountID).appendingPathComponent("MetadataOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(id.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = folder.appendingPathComponent("\(name).json")
        try encoder.encode(payload).write(to: url, options: .atomic)
        record["payloadFile"] = CKAsset(fileURL: url)
        return record
    }

    private func payload(in record: CKRecord) throws -> CloudMetadataPayload {
        guard record.recordType == "PageKeepOperation" else { throw CloudSyncError.invalidCloudRecord }
        let data: Data
        if let asset = record["payloadFile"] as? CKAsset, let url = asset.fileURL { data = try Data(contentsOf: url) }
        else if let inline = record["payload"] as? Data { data = inline }
        else { throw CloudSyncError.invalidCloudRecord }
        let payload = try JSONDecoder().decode(CloudMetadataPayload.self, from: data)
        try payload.validate()
        if let operation = payload.operation,
           record.recordID.recordName != "operation-\(operation.id.uuidString)" { throw CloudSyncError.invalidCloudRecord }
        if let seed = payload.orderSeed,
           (UUID(uuidString: seed.id) == nil || record.recordID.recordName != "seed-\(seed.id)") { throw CloudSyncError.invalidCloudRecord }
        return payload
    }

    private func cacheRecord(_ record: CKRecord) throws {
        guard record.recordID.zoneID == metadataZone else { return }
        let value = try payload(in: record)
        if let existing = cache?.metadata[record.recordID.recordName], !existing.hasSameContents(as: value) {
            throw CloudSyncError.immutableRecordChanged
        }
        cache?.metadata[record.recordID.recordName] = value
        if let asset = record["payloadFile"] as? CKAsset, let source = asset.fileURL, let accountID {
            let folder = accountFolder(for: accountID).appendingPathComponent("MetadataInbox", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = SHA256.hash(data: Data(record.recordID.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
            let owned = folder.appendingPathComponent("\(name).json")
            try Data(contentsOf: source).write(to: owned, options: .atomic)
        }
    }

    private func commitCheckpoint() throws {
        if let sessionError { throw sessionError }
        cache?.engineState = pendingSerialization ?? cache?.engineState
        try persistCache()
    }

    private func persistCache() throws {
        guard let cache else { throw CancellationError() }
        let url = cacheURL(for: cache.accountID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }

    private func accountFolder(for account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent(key, isDirectory: true)
    }

    private func cacheURL(for account: String) -> URL { accountFolder(for: account).appendingPathComponent("inbox.json") }

    private func session() throws -> (CKSyncEngine, String, UUID) {
        guard let engine, let accountID else { throw CancellationError() }
        return (engine, accountID, generation)
    }

    private func checkSession(_ token: UUID) throws {
        guard generation == token, engine != nil, accountID != nil, !Task.isCancelled else { throw CancellationError() }
    }

    private func validateSession(account: String, token: UUID) async throws {
        try checkSession(token)
        guard try await accountIdentifier() == account else { throw CloudSyncError.accountChanged }
        try checkSession(token)
    }

    private func downloadPDF(for notebook: Notebook, account: String, token: UUID) async throws -> URL {
        guard let revision = notebook.revisionID else { throw CloudSyncError.assetUnavailable }
        let folder = accountFolder(for: account).appendingPathComponent("PDFs", isDirectory: true)
        let destination = folder.appendingPathComponent("\(revision.uuidString).pdf")
        if let digest = cache?.revisionDigests[revision.uuidString], FileManager.default.fileExists(atPath: destination.path) {
            let pageCount = notebook.pageCount
            let isValid = await Task.detached(priority: .utility) {
                (try? Self.fileDigest(destination)) == digest
                    && (try? PDFService.validate(at: destination).pageCount) == pageCount
            }.value
            try checkSession(token)
            if isValid { return destination }
        }
        let record = try await fetchRecord(CKRecord.ID(recordName: revision.uuidString, zoneID: assetZone), token: token)
        try checkSession(token)
        guard let asset = record["pdf"] as? CKAsset, let source = asset.fileURL,
              let digest = record["digest"] as? String else { throw CloudSyncError.assetUnavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        let pageCount = notebook.pageCount
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: staged)
            guard try Self.fileDigest(staged) == digest,
                  try PDFService.validate(at: staged).pageCount == pageCount else { throw CloudSyncError.assetUnavailable }
        }.value
        try checkSession(token)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        cache?.revisionDigests[revision.uuidString] = digest
        try persistCache()
        return destination
    }

    private func uploadPDF(at url: URL, notebook: Notebook, token: UUID) async throws {
        guard let revision = notebook.revisionID else { return }
        let digest = try await Task.detached(priority: .utility) { try Self.fileDigest(url) }.value
        let id = CKRecord.ID(recordName: revision.uuidString, zoneID: assetZone)
        do {
            let existing = try await fetchRecord(id, token: token, desiredKeys: ["digest"])
            guard existing["digest"] as? String == digest else { throw CloudSyncError.immutableRecordChanged }
            return
        } catch let error as CKError where error.code == .unknownItem { }
        try checkSession(token)
        let record = CKRecord(recordType: "PageKeepPDFRevision", recordID: id)
        record["digest"] = digest as NSString
        record["pdf"] = CKAsset(fileURL: url)
        do { _ = try await saveRecord(record, token: token) }
        catch let error as CKError where error.code == .serverRecordChanged {
            let saved = try await fetchRecord(id, token: token, desiredKeys: ["digest"])
            guard saved["digest"] as? String == digest else { throw CloudSyncError.immutableRecordChanged }
        }
    }

    nonisolated private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fetchRecord(_ id: CKRecord.ID, token: UUID, desiredKeys: [String]? = nil) async throws -> CKRecord {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.desiredKeys = desiredKeys
        let result = CloudRecordResult()
        operation.perRecordResultBlock = { _, value in result.set(value) }
        return try await runRecordOperation(operation, token: token, result: result) { finish in
            operation.fetchRecordsResultBlock = finish
        }
    }

    private func saveRecord(_ record: CKRecord, token: UUID) async throws -> CKRecord {
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .ifServerRecordUnchanged
        let result = CloudRecordResult()
        operation.perRecordSaveBlock = { _, value in result.set(value) }
        return try await runRecordOperation(operation, token: token, result: result) { finish in
            operation.modifyRecordsResultBlock = finish
        }
    }

    private func runRecordOperation(
        _ operation: CKDatabaseOperation, token: UUID, result: CloudRecordResult,
        completion: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    ) async throws -> CKRecord {
        try checkSession(token)
        let id = UUID()
        operations[id] = operation
        defer { operations.removeValue(forKey: id) }
        let record: CKRecord = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion { overall in
                    switch result.get() {
                    case .some(let value): continuation.resume(with: value)
                    case .none:
                        if case .failure(let error) = overall { continuation.resume(throwing: error) }
                        else { continuation.resume(throwing: CloudSyncError.invalidCloudRecord) }
                    }
                }
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: { operation.cancel() }
        try checkSession(token)
        return record
    }

    private func saveAssetZone(token: UUID) async throws {
        try checkSession(token)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: assetZone)])
        let id = UUID()
        operations[id] = operation
        defer { operations.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordZonesResultBlock = { continuation.resume(with: $0) }
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: { operation.cancel() }
        try checkSession(token)
    }
}

private final class CloudRecordResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CKRecord, Error>?

    func set(_ result: Result<CKRecord, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.result = result
    }

    func get() -> Result<CKRecord, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
