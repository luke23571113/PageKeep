import SwiftUI

@main
struct PageKeepApp: App {
    @State private var store: LibraryStore

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PageKeep-UITests", isDirectory: true)
            if arguments.contains("--reset-ui-tests") {
                try? FileManager.default.removeItem(at: root)
            }
            _store = State(initialValue: LibraryStore(repository: LibraryRepository(rootURL: root)))
        } else {
            _store = State(initialValue: LibraryStore())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
