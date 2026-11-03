import SwiftUI
import Observation

@MainActor
@Observable
final class FolderExpansionStore {
    static let expandedKey = "expandedLibraryFolders"
    @ObservationIgnored private let defaults: UserDefaults
    private var expandedIDs: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expandedIDs = Set((defaults.stringArray(forKey: Self.expandedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func isExpanded(_ id: UUID) -> Bool { expandedIDs.contains(id) }

    func setExpanded(_ expanded: Bool, for id: UUID) {
        if expanded { expandedIDs.insert(id) }
        else { expandedIDs.remove(id) }
        defaults.set(expandedIDs.map(\.uuidString).sorted(), forKey: Self.expandedKey)
    }
}

struct FolderPicker: View {
    let store: LibraryStore
    @Binding var selection: UUID?

    private var availableSelection: Binding<UUID?> {
        Binding(
            get: { selection.flatMap { store.folder(id: $0)?.id } },
            set: { selection = $0 }
        )
    }

    var body: some View {
        Picker("Folder", selection: availableSelection) {
            Text("No Folder").tag(UUID?.none)
            ForEach(store.folders) { folder in
                Text(folder.name).tag(Optional(folder.id))
            }
        }
        .accessibilityIdentifier("editor.folder")
        if let selection, store.folder(id: selection) == nil {
            Text("This folder is unavailable. The notebook will appear in the main list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MoveToFolderMenu: View {
    let store: LibraryStore
    let notebook: Notebook
    let onError: (String) -> Void
    @Environment(FolderExpansionStore.self) private var expansion
    @State private var isMoving = false

    var body: some View {
        Menu("Move to Folder", systemImage: "folder") {
            destination("No Folder", id: nil)
            ForEach(store.folders) { folder in
                destination(folder.name, id: folder.id)
            }
        }
        .disabled(store.isBusy || isMoving)
    }

    private func destination(_ name: String, id: UUID?) -> some View {
        Button {
            guard !isMoving, !store.isBusy else { return }
            isMoving = true
            Task {
                defer { isMoving = false }
                do {
                    try await store.moveNotebook(notebook.id, toFolderID: id)
                    if let id { expansion.setExpanded(true, for: id) }
                } catch { onError(error.localizedDescription) }
            }
        } label: {
            if store.effectiveFolderID(for: notebook) == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
        .disabled(store.effectiveFolderID(for: notebook) == id)
    }
}
