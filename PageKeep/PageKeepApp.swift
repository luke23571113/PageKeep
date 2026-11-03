import SwiftUI

@main
struct PageKeepApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var appDelegate
#else
    @UIApplicationDelegateAdaptor(CloudNotificationDelegate.self) private var appDelegate
#endif
    @State private var store: LibraryStore
    @State private var settings: AppSettings
    @State private var readingPositions: ReadingPositionStore
    @State private var folderExpansion: FolderExpansionStore
    @State private var cloudSync: CloudSyncCoordinator

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let defaults: UserDefaults
        let repository: LibraryRepository
        if arguments.contains("--ui-testing") || isTestHost {
            let suiteName = "com.lukecollins.PageKeep.UITests"
            defaults = UserDefaults(suiteName: suiteName)!
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PageKeep-UITests", isDirectory: true)
            if arguments.contains("--reset-ui-tests") {
                try? FileManager.default.removeItem(at: root)
                defaults.removePersistentDomain(forName: suiteName)
            }
            repository = LibraryRepository(rootURL: root)
        } else {
            defaults = .standard
            repository = LibraryRepository()
        }
        let library = LibraryStore(repository: repository)
        _store = State(initialValue: library)
        _settings = State(initialValue: AppSettings(defaults: defaults))
        _readingPositions = State(initialValue: ReadingPositionStore(defaults: defaults))
        _folderExpansion = State(initialValue: FolderExpansionStore(defaults: defaults))
        _cloudSync = State(initialValue: CloudSyncCoordinator(store: library, defaults: defaults))
    }

    var body: some Scene {
#if os(macOS)
        Window("PageKeep", id: "library") {
            MacContentView(store: store)
                .environment(settings)
                .environment(readingPositions)
                .environment(folderExpansion)
                .environment(cloudSync)
                .modifier(CloudSyncLifecycle(store: store, cloudSync: cloudSync))
                .preferredColorScheme(settings.appearance.colorScheme)
                .task { configureCloudNotifications() }
        }
        .defaultSize(width: 960, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .init("PageKeep.showSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
#else
        WindowGroup {
            ContentView(store: store)
                .environment(settings)
                .environment(readingPositions)
                .environment(folderExpansion)
                .environment(cloudSync)
                .modifier(CloudSyncLifecycle(store: store, cloudSync: cloudSync))
                .preferredColorScheme(settings.appearance.colorScheme)
                .task { configureCloudNotifications() }
        }
#endif
    }

    private func configureCloudNotifications() {
        guard cloudSync.isAvailable else { return }
#if os(macOS)
        appDelegate.cloudSync = cloudSync
        NSApplication.shared.registerForRemoteNotifications()
#else
        appDelegate.coordinator = cloudSync
        UIApplication.shared.registerForRemoteNotifications()
#endif
    }
}
