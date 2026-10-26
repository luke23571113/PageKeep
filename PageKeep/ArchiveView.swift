import SwiftUI

struct ArchiveView: View {
    let store: LibraryStore
    @State private var isRestoring = false
    @State private var selection: Set<UUID> = []
    @State private var presentation = NotebookPresentation()

    private var isBusy: Bool { store.isBusy || isRestoring }

    var body: some View {
        Group {
            if store.archivedNotebooks.isEmpty {
                ContentUnavailableView("No Archived Notebooks", systemImage: "archivebox", description: Text("Notebooks you archive appear here. You can bring them back anytime."))
            } else {
                List {
                    ForEach(store.archivedNotebooks) { notebook in
                        Button {
                            if selection.contains(notebook.id) {
                                selection.remove(notebook.id)
                            } else {
                                selection.insert(notebook.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selection.contains(notebook.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(notebook.id) ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                NotebookIcon(notebook: notebook)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(notebook.name).foregroundStyle(.primary)
                                    Text(notebook.pageCountLabel).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selection.contains(notebook.id) ? .isSelected : [])
                        .accessibilityHint("Select to unarchive")
                        .accessibilityIdentifier("archive.notebook.\(notebook.id.uuidString)")
                        .contextMenu {
                            Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive([notebook.id]) }
                            Button(role: .destructive) {
                                presentation.notebookToDelete = notebook
                            } label: {
                                PermanentDeleteLabel()
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Archived Notebooks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == store.archivedNotebooks.count && !selection.isEmpty ? "Deselect All" : "Select All") {
                    if selection.count == store.archivedNotebooks.count {
                        selection.removeAll()
                    } else {
                        selection = Set(store.archivedNotebooks.map(\.id))
                    }
                }
                .accessibilityIdentifier("archive.selectAll")
                .disabled(store.archivedNotebooks.isEmpty || isBusy)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive(selection) }
                    .accessibilityIdentifier("archive.unarchive")
                    .disabled(selection.isEmpty || isBusy)
            }
        }
        .disabled(isBusy)
        .notebookPresentations(store: store, presentation: presentation) { _, _ in }
        .onChange(of: store.archivedNotebooks.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
    }

    private func unarchive(_ ids: Set<UUID>) {
        guard !isBusy else { return }
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await store.setArchived(false, ids: ids)
                selection.subtract(ids)
            } catch {
                presentation.errorMessage = error.localizedDescription
            }
        }
    }
}
