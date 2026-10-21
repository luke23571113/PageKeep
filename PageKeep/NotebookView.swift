import SwiftUI
import Observation

struct NotebookView: View {
    let store: LibraryStore
    let notebookID: UUID
    @State private var currentPageID: UUID?
    @State private var knownPageIDs: [UUID] = []
    @State private var presentation = NotebookPresentation()
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, notebookID: UUID, initialPageID: UUID? = nil) {
        self.store = store
        self.notebookID = notebookID
        _currentPageID = State(initialValue: initialPageID)
    }

    var body: some View {
        Group {
            if let notebook = store.notebook(id: notebookID) {
                notebookContent(notebook)
                    .navigationTitle(notebook.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { notebookToolbar(notebook) }
                    .onChange(of: notebook.pages.map(\.id), initial: true) { _, ids in
                        followCurrentPage(in: ids)
                    }
            } else {
                ContentUnavailableView("Notebook Deleted", systemImage: "book.closed")
            }
        }
        .notebookPresentations(store: store, presentation: presentation) { _, pageID in
            if let pageID { currentPageID = pageID }
        }
        .onChange(of: store.notebook(id: notebookID) == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    @ViewBuilder
    private func notebookContent(_ notebook: Notebook) -> some View {
        if let error = store.notebookErrors[notebookID] {
            ContentUnavailableView {
                Label("Pages Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if notebook.pages.isEmpty {
            ContentUnavailableView {
                Label("No Pages Yet", systemImage: "doc")
            } description: {
                Text("Add scans or a PDF to this notebook.")
            } actions: {
                Button("Add Pages", systemImage: "doc.badge.plus") {
                    presentation.show(.acquisition(notebookID, nil))
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
            }
        } else if let url = store.pdfURL(for: notebook) {
            VStack(spacing: 0) {
                PDFReader(url: url, pageIDs: notebook.pages.map(\.id), currentPageID: $currentPageID)
                HStack {
                    Text(pagePosition(in: notebook))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if store.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving changes")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.bar)
            }
        } else {
            ContentUnavailableView("Pages Unavailable", systemImage: "exclamationmark.triangle", description: Text("The saved PDF could not be found."))
        }
    }

    @ToolbarContentBuilder
    private func notebookToolbar(_ notebook: Notebook) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                NotebookMenuActions(store: store, notebook: notebook, presentation: presentation)
            } label: {
                Label("Notebook Actions", systemImage: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("viewer.actions")
            .disabled(store.isBusy)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Add Pages", systemImage: "doc.badge.plus") {
                presentation.show(.acquisition(notebookID, nil))
            }
            .accessibilityIdentifier("viewer.add")
            .disabled(store.isBusy || store.notebookErrors[notebookID] != nil)
            Spacer()
            Button("Manage", systemImage: "square.grid.2x2") {
                presentation.show(.manage(notebookID))
            }
            .accessibilityIdentifier("viewer.manage")
            .disabled(store.isBusy || store.notebookErrors[notebookID] != nil)
            Spacer()
            Button("Share", systemImage: "square.and.arrow.up") {
                presentation.share(notebook, store: store)
            }
            .accessibilityIdentifier("viewer.share")
            .disabled(store.isBusy || notebook.pages.isEmpty || store.notebookErrors[notebookID] != nil)
        }
    }

    private func pagePosition(in notebook: Notebook) -> String {
        let index = notebook.pages.firstIndex { $0.id == currentPageID } ?? 0
        return "Page \(index + 1) of \(notebook.pageCount)"
    }

    private func followCurrentPage(in ids: [UUID]) {
        if let currentPageID, ids.contains(currentPageID) {
            knownPageIDs = ids
            return
        }
        let previousIndex = knownPageIDs.firstIndex { $0 == currentPageID } ?? 0
        currentPageID = ids.isEmpty ? nil : ids[min(previousIndex, ids.count - 1)]
        knownPageIDs = ids
    }
}

@MainActor
@Observable
final class NotebookPresentation {
    var sheet: NotebookSheet?
    var notebookToDelete: Notebook?
    var errorMessage: String?
    var pendingShareError: String?

    func show(_ kind: NotebookSheet.Kind) {
        sheet = NotebookSheet(kind: kind)
    }

    func share(_ notebook: Notebook, store: LibraryStore) {
        Task {
            do {
                show(.share(try await store.shareCopy(of: notebook.id)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct NotebookSheet: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case acquisition(UUID?, AcquisitionSource?)
        case manage(UUID)
        case rename(UUID)
        case share(URL)
    }
}

struct NotebookMenuActions: View {
    let store: LibraryStore
    let notebook: Notebook
    let presentation: NotebookPresentation

    var body: some View {
        Button("Rename", systemImage: "pencil") {
            presentation.show(.rename(notebook.id))
        }
        Button("Add Pages", systemImage: "doc.badge.plus") {
            presentation.show(.acquisition(notebook.id, nil))
        }
        .disabled(store.notebookErrors[notebook.id] != nil)
        Button("Manage Pages", systemImage: "square.grid.2x2") {
            presentation.show(.manage(notebook.id))
        }
        .disabled(store.notebookErrors[notebook.id] != nil)
        Button("Share PDF", systemImage: "square.and.arrow.up") {
            presentation.share(notebook, store: store)
        }
        .disabled(notebook.pages.isEmpty || store.notebookErrors[notebook.id] != nil)
        Button("Delete Notebook", systemImage: "trash", role: .destructive) {
            presentation.notebookToDelete = notebook
        }
    }
}

private struct NotebookPresentationModifier: ViewModifier {
    let store: LibraryStore
    @Bindable var presentation: NotebookPresentation
    let onOpen: (UUID, UUID?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation.sheet, onDismiss: {
                if let error = presentation.pendingShareError {
                    presentation.pendingShareError = nil
                    presentation.errorMessage = error
                }
            }) { sheet in
                switch sheet.kind {
                case let .acquisition(id, source):
                    AcquisitionView(store: store, notebookID: id, initialSource: source, onSaved: onOpen)
                case let .manage(id):
                    NavigationStack {
                        PageManagementView(store: store, notebookID: id) { pageID in
                            presentation.sheet = nil
                            onOpen(id, pageID)
                        }
                    }
                case let .rename(id):
                    RenameNotebookView(store: store, notebookID: id)
                case let .share(url):
                    ShareSheet(url: url) { error in
                        presentation.pendingShareError = "The PDF could not be shared. Please try Share PDF again. \(error.localizedDescription)"
                    }
                }
            }
            .confirmationDialog(
                "Delete \(presentation.notebookToDelete?.name ?? "Notebook")?",
                isPresented: Binding(
                    get: { presentation.notebookToDelete != nil },
                    set: { if !$0 { presentation.notebookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let notebook = presentation.notebookToDelete {
                    Button("Delete Notebook", role: .destructive) {
                        Task {
                            do { try await store.deleteNotebook(notebook.id) }
                            catch { presentation.errorMessage = error.localizedDescription }
                        }
                    }
                }
            } message: {
                Text("This permanently deletes the notebook and all its pages.")
            }
            .alert("Couldn’t Complete Action", isPresented: Binding(
                get: { presentation.errorMessage != nil },
                set: { if !$0 { presentation.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { presentation.errorMessage = nil }
            } message: {
                Text(presentation.errorMessage ?? "Please try again.")
            }
    }
}

extension View {
    func notebookPresentations(
        store: LibraryStore,
        presentation: NotebookPresentation,
        onOpen: @escaping (UUID, UUID?) -> Void
    ) -> some View {
        modifier(NotebookPresentationModifier(store: store, presentation: presentation, onOpen: onOpen))
    }
}

private struct RenameNotebookView: View {
    let store: LibraryStore
    let notebookID: UUID
    @State private var name = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Notebook name", text: $name)
                    .accessibilityIdentifier("rename.name")
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle("Rename Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("rename.save")
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                }
            }
            .interactiveDismissDisabled(store.isBusy)
            .onAppear { name = store.notebook(id: notebookID)?.name ?? "" }
            .alert("Couldn’t Rename Notebook", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !store.isBusy else { return }
        Task {
            do {
                try await store.rename(notebookID, to: trimmedName)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
