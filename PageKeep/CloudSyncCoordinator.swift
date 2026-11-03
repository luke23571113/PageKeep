import Foundation
import Observation
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

struct CloudSyncDownload {
    let manifest: LibraryManifest
    let pdfURLs: [UUID: URL]
}

struct CloudSyncUpload {
    let acknowledgedIDs: Set<UUID>
    var retryMessage: String? = nil
    var retryAfterSeconds: Double? = nil
}

@MainActor
protocol CloudSyncTransport: AnyObject {
    var onRemoteChange: (() -> Void)? { get set }
    var onProgress: ((Double?) -> Void)? { get set }
    func accountIdentifier() async throws -> String
    func start(accountID: String) async throws
    func stop() async
    func resetAccountState(accountID: String) throws
    func fetchChanges(existingPDFs: [UUID: URL]) async throws -> CloudSyncDownload
    func sendChanges(_ manifest: LibraryManifest, pdfURLs: [UUID: URL]) async throws -> CloudSyncUpload
}

@MainActor
@Observable
final class CloudSyncCoordinator {
    private(set) var isEnabled: Bool
    private(set) var status: String
    private(set) var errorMessage: String?
    private(set) var progress: Double?
    private(set) var needsAccountConfirmation = false
    let isAvailable: Bool

    static let enabledKey = "cloudSyncEnabled"
    static let accountKey = "cloudSyncAccount"
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: (any CloudSyncTransport)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var pendingAccountID: String?
    @ObservationIgnored private var nextRetryDate: Date?
    @ObservationIgnored private var failedAttempts = 0

    init(
        store: LibraryStore,
        defaults: UserDefaults = .standard,
        transport: (any CloudSyncTransport)? = nil,
        isAvailable: Bool? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        let configured = isAvailable ?? (transport != nil || Bundle.main.object(forInfoDictionaryKey: "PageKeepCloudKitEnabled") as? Bool == true)
        self.isAvailable = configured
        if configured {
            let root = store.repository.rootURL.deletingLastPathComponent().appendingPathComponent("CloudSync", isDirectory: true)
            self.transport = transport ?? CloudKitTransport(rootURL: root)
        } else {
            self.transport = nil
        }
        let enabled = configured && defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        status = configured ? (enabled ? "Waiting to sync" : "iCloud sync is off") : "iCloud sync needs app setup"
        self.transport?.onRemoteChange = { [weak self] in
            guard let self, self.isEnabled else { return }
            Task { await self.refresh() }
        }
        self.transport?.onProgress = { [weak self] progress in
            guard let self, self.isEnabled else { return }
            self.progress = progress
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        guard !enabled || isAvailable else {
            errorMessage = "iCloud capabilities must be configured for this app before sync can be enabled. Your local notebooks are available."
            return
        }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        progress = nil
        errorMessage = nil
        needsAccountConfirmation = false
        pendingAccountID = nil
        nextRetryDate = nil
        failedAttempts = 0
        let token = generation
        await transport?.stop()
        guard generation == token, isEnabled == enabled else { return }
        if enabled {
            status = "Waiting to sync"
            await refresh()
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
            status = "iCloud sync is off"
        }
    }

    func sceneBecameActive() async {
        isSceneActive = true
        await refresh()
        startPolling()
    }

    func sceneBecameInactive() {
        isSceneActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    func handleRemoteNotification() async -> Bool {
        let notebooks = store.notebooks
        let folders = store.folders
        let rootOrder = store.rootItems.map(\.id)
        let pendingCount = store.pendingSyncCount
        await refresh()
        return notebooks != store.notebooks || folders != store.folders
            || rootOrder != store.rootItems.map(\.id) || pendingCount != store.pendingSyncCount
    }

    func refresh() async {
        guard isEnabled, isAvailable, transport != nil else { return }
        if let nextRetryDate, nextRetryDate > now() { return }
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        let token = generation
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runRefresh(token: token)
        }
        refreshTask = task
        await task.value
        guard generation == token else { return }
        refreshTask = nil
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    func confirmAccountChange() async {
        guard isEnabled, needsAccountConfirmation, let expectedAccount = pendingAccountID, let transport else { return }
        let token = generation
        do {
            let accountID = try await transport.accountIdentifier()
            try checkSession(token)
            guard accountID == expectedAccount else {
                pendingAccountID = accountID
                errorMessage = "The Apple account changed again. Confirm the currently signed-in account before syncing."
                return
            }
            await transport.stop()
            try checkSession(token)
            // Old-account tombstones and operations must never be sent to another account.
            try await store.resetSyncForNewAccount()
            try checkSession(token)
            try transport.resetAccountState(accountID: accountID)
            defaults.set(accountID, forKey: Self.accountKey)
            needsAccountConfirmation = false
            pendingAccountID = nil
            errorMessage = nil
            nextRetryDate = nil
            failedAttempts = 0
            await refresh()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            status = "Waiting to sync"
        }
    }

    private func runRefresh(token: UUID) async {
        guard let transport else { return }
        do {
            try checkSession(token)
            status = "Checking iCloud…"
            errorMessage = nil
            let accountID = try await transport.accountIdentifier()
            try checkSession(token)
            if let previous = defaults.string(forKey: Self.accountKey), previous != accountID {
                pendingAccountID = accountID
                needsAccountConfirmation = true
                progress = nil
                status = "Confirm the Apple account change"
                await transport.stop()
                return
            }
            guard !needsAccountConfirmation else { return }
            defaults.set(accountID, forKey: Self.accountKey)
            await store.load()
            try checkSession(token)
            if let loadError = store.loadError { throw CloudSyncError.libraryUnavailable(loadError) }
            try await store.prepareForSync()
            try checkSession(token)
            try await transport.start(accountID: accountID)
            try checkSession(token)
            let local = try await store.repository.syncSnapshot()
            let existingPDFs = pdfURLs(in: local.notebooks)
            status = "Downloading iCloud changes…"
            let remote = try await transport.fetchChanges(existingPDFs: existingPDFs)
            try checkSession(token)
            guard try await transport.accountIdentifier() == accountID else { throw CloudSyncError.accountChanged }
            try checkSession(token)
            try await store.applyRemote(remote.manifest, downloadedPDFs: remote.pdfURLs)
            try checkSession(token)
            let outgoing = try await store.repository.syncSnapshot()
            status = "Uploading changes…"
            let upload = try await transport.sendChanges(outgoing, pdfURLs: pdfURLs(in: outgoing.sync.outbox.compactMap(\.notebook)))
            try checkSession(token)
            guard try await transport.accountIdentifier() == accountID else { throw CloudSyncError.accountChanged }
            try checkSession(token)
            if !upload.acknowledgedIDs.isEmpty { try await store.acknowledgeSyncEntries(upload.acknowledgedIDs) }
            try checkSession(token)
            progress = nil
            errorMessage = upload.retryMessage
            status = upload.retryMessage == nil && store.pendingSyncCount == 0 ? "Up to date" : "Waiting to sync"
            if upload.retryMessage != nil { scheduleRetry(serverDelay: upload.retryAfterSeconds) }
            else { failedAttempts = 0; nextRetryDate = nil }
        } catch is CancellationError {
        } catch {
            guard generation == token, isEnabled else { return }
            await transport.stop()
            guard generation == token, isEnabled else { return }
            progress = nil
            errorMessage = error.localizedDescription
            status = "Waiting to sync"
            if case CloudSyncError.accountChanged = error {
                refreshAgain = true
            } else {
                scheduleRetry(serverDelay: (error as? CKError)?.retryAfterSeconds)
            }
        }
    }

    private func checkSession(_ token: UUID) throws {
        guard isEnabled, generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func pdfURLs(in notebooks: [Notebook]) -> [UUID: URL] {
        var result: [UUID: URL] = [:]
        for notebook in notebooks {
            if let revisionID = notebook.revisionID, let url = store.pdfURL(for: notebook) {
                result[revisionID] = url
            }
        }
        return result
    }

    private func startPolling() {
        guard isSceneActive, isEnabled, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.isSceneActive, self.isEnabled else { return }
                await self.refresh()
            }
        }
    }

    private func scheduleRetry(serverDelay: Double?) {
        failedAttempts += 1
        let delay = max(serverDelay ?? 0, min(15 * pow(2, Double(min(failedAttempts - 1, 5))), 300))
        nextRetryDate = now().addingTimeInterval(delay)
    }
}

#if canImport(UIKit)
@MainActor
final class CloudNotificationDelegate: NSObject, UIApplicationDelegate {
    weak var coordinator: CloudSyncCoordinator?

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let coordinator, coordinator.isAvailable, coordinator.isEnabled else {
            completionHandler(.noData)
            return
        }
        Task {
            let changed = await coordinator.handleRemoteNotification()
            completionHandler(changed ? .newData : .noData)
        }
    }
}
#endif

enum CloudSyncError: LocalizedError {
    case accountUnavailable
    case accountChanged
    case invalidCloudRecord
    case newerCloudSchema
    case assetUnavailable
    case immutableRecordChanged
    case cloudDataRemoved
    case libraryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: "Sign in to iCloud in device settings to sync your notebooks. Local notebooks remain available."
        case .accountChanged: "The Apple account changed. Sync is paused until the account is checked again."
        case .invalidCloudRecord: "An iCloud library record could not be read. Your saved local library has been kept."
        case .newerCloudSchema: "This iCloud library needs a newer version of PageKeep. Update the app to continue syncing. Your local notebooks have been kept."
        case .assetUnavailable: "A notebook PDF could not be downloaded completely. Please try again."
        case .immutableRecordChanged: "An iCloud revision did not match its saved identity. Your local copy has been kept."
        case .cloudDataRemoved: "iCloud library history was removed unexpectedly. Sync is paused to protect saved notebooks."
        case .libraryUnavailable(let message): message
        }
    }
}
