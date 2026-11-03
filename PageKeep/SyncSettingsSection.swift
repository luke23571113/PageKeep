import SwiftUI

struct SyncSettingsSection: View {
    let store: LibraryStore
    @Environment(CloudSyncCoordinator.self) private var cloudSync
    @State private var changingSetting = false
    @State private var noticeError: String?

    var body: some View {
        Section {
            Toggle("iCloud Sync", isOn: Binding(
                get: { cloudSync.isEnabled },
                set: { enabled in
                    changingSetting = true
                    Task {
                        await cloudSync.setEnabled(enabled)
                        changingSetting = false
                    }
                }
            ))
            .disabled(!cloudSync.isAvailable || changingSetting)
            .accessibilityIdentifier("settings.cloudSync")
            Text(cloudSync.status).font(.caption).foregroundStyle(.secondary)
            if let progress = cloudSync.progress {
                ProgressView(value: progress).accessibilityLabel("Library sync progress")
            }
            if let error = cloudSync.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if cloudSync.isEnabled {
                Button("Refresh / Retry") { Task { await cloudSync.refresh() } }
                    .disabled(changingSetting)
            }
            if cloudSync.needsAccountConfirmation {
                Text("The iCloud account changed. Connecting will upload this device’s retained notebooks to the current account. The previous account’s cloud data will stay there.")
                    .font(.caption)
                Button("Connect Retained Notebooks to This Account") {
                    Task { await cloudSync.confirmAccountChange() }
                }
            }
            ForEach(store.syncNotices) { notice in
                HStack {
                    Text(notice.message)
                    Spacer()
                    Button("Dismiss") {
                        Task {
                            do { try await store.dismissSyncNotice(notice.id) }
                            catch { noticeError = error.localizedDescription }
                        }
                    }
                    .disabled(store.isBusy)
                }
                .font(.caption)
            }
            if let noticeError { Text(noticeError).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Syncs all notebooks, including archives. Downloaded PDFs stay on this device when sync is turned off. Reading positions and app settings stay on this device.")
        }
    }
}

struct CloudSyncLifecycle: ViewModifier {
    let store: LibraryStore
    let cloudSync: CloudSyncCoordinator
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if let notice = store.syncNotices.first {
                    HStack {
                        Label(
                            notice.message,
                            systemImage: "doc.on.doc"
                        )
                        Spacer()
                        Button("Dismiss") {
                            Task { try? await store.dismissSyncNotice(notice.id) }
                        }
                        .disabled(store.isBusy)
                    }
                    .font(.callout)
                    .padding()
                    .background(.bar)
                    .accessibilityIdentifier("library.syncNotice")
                }
            }
            .task {
                await store.load()
                await cloudSync.sceneBecameActive()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await cloudSync.sceneBecameActive() } }
                else { cloudSync.sceneBecameInactive() }
            }
            .onChange(of: store.pendingSyncCount) { _, _ in
                if cloudSync.isEnabled { Task { await cloudSync.refresh() } }
            }
    }
}

private extension LibrarySyncNotice {
    var message: String {
        switch kind {
        case .conflict: "Conflicting edits were kept in a separate notebook."
        case .recovered: "Offline edits were kept in a recovered notebook."
        case .metadataConflict: details ?? "Notebook details changed on another device."
        }
    }
}
