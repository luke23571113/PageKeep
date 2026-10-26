import SwiftUI

@main
struct PageKeepApp: App {
    @State private var store: LibraryStore
    @State private var settings: AppSettings

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            let suiteName = "com.lukecollins.PageKeep.UITests"
            let defaults = UserDefaults(suiteName: suiteName)!
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PageKeep-UITests", isDirectory: true)
            if arguments.contains("--reset-ui-tests") {
                try? FileManager.default.removeItem(at: root)
                defaults.removePersistentDomain(forName: suiteName)
            }
            _store = State(initialValue: LibraryStore(repository: LibraryRepository(rootURL: root)))
            _settings = State(initialValue: AppSettings(defaults: defaults))
        } else {
            _store = State(initialValue: LibraryStore())
            _settings = State(initialValue: AppSettings())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
