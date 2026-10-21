import SwiftUI

struct ContentView: View {
    let store: LibraryStore
    @State private var path: [UUID] = []
    @State private var initialPageID: UUID?
    @State private var presentation = NotebookPresentation()
    @State private var showsRecoveryConfirmation = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isLoading {
                    ProgressView("Loading notebooks…")
                } else if let error = store.loadError {
                    storageError(error)
                } else if store.notebooks.isEmpty {
                    emptyLibrary
                } else {
                    notebookList
                }
            }
            .navigationTitle("Notebooks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    createNotebookMenu
                        .disabled(store.isBusy || store.loadError != nil)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                NotebookView(store: store, notebookID: id, initialPageID: initialPageID)
            }
        }
        .notebookPresentations(store: store, presentation: presentation) { id, pageID in
            initialPageID = pageID
            path = [id]
        }
        .task { await store.load() }
    }

    private var notebookList: some View {
        List {
            ForEach(store.notebooks) { notebook in
                NavigationLink(value: notebook.id) {
                    NotebookRow(notebook: notebook, error: store.notebookErrors[notebook.id])
                }
                .accessibilityIdentifier("library.notebook.\(notebook.id.uuidString)")
                .contextMenu {
                    NotebookMenuActions(store: store, notebook: notebook, presentation: presentation)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        presentation.show(.acquisition(notebook.id, nil))
                    } label: {
                        Label("Add Pages", systemImage: "doc.badge.plus")
                    }
                    .tint(.accentColor)
                    .disabled(store.isBusy || store.notebookErrors[notebook.id] != nil)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        presentation.notebookToDelete = notebook
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        presentation.show(.manage(notebook.id))
                    } label: {
                        Label("Manage", systemImage: "square.grid.2x2")
                    }
                    .tint(.secondary)
                    .disabled(store.notebookErrors[notebook.id] != nil)
                }
                .disabled(store.isBusy)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var createNotebookMenu: some View {
        Menu {
            Section("Create New Notebook") {
                Button {
                    presentation.show(.acquisition(nil, .scan))
                } label: {
                    Label("Scan Pages", systemImage: "doc.viewfinder")
                }
                Button {
                    presentation.show(.acquisition(nil, .importPDF))
                } label: {
                    Label("Import PDF", systemImage: "doc.badge.plus")
                }
            }
        } label: {
            Label("Create New Notebook", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Create new notebook")
        .accessibilityIdentifier("library.create")
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Notebooks Yet", systemImage: "book.closed")
        } description: {
            Text("Scan paper pages or import a PDF to create your first notebook.")
        } actions: {
            Button("Scan Pages", systemImage: "doc.viewfinder") {
                presentation.show(.acquisition(nil, .scan))
            }
            .buttonStyle(.borderedProminent)
            Button("Import PDF", systemImage: "doc.badge.plus") {
                presentation.show(.acquisition(nil, .importPDF))
            }
            .buttonStyle(.bordered)
        }
        .disabled(store.isBusy)
    }

    private func storageError(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Notebooks", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(error)
        } actions: {
            Button("Try Again") { Task { await store.reload() } }
                .buttonStyle(.borderedProminent)
            if store.canRecover {
                Button("Recover Saved Library") { showsRecoveryConfirmation = true }
                    .buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Restore the previous saved library?", isPresented: $showsRecoveryConfirmation, titleVisibility: .visible) {
            Button("Recover Saved Library") { Task { await store.recover() } }
        } message: {
            Text("Changes after that save may be lost. Your PDF files will not be removed during recovery.")
        }
    }
}

private struct NotebookRow: View {
    let notebook: Notebook
    let error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "book.closed")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(notebook.pageCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Modified \(notebook.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if error != nil {
                    Label("Pages unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
