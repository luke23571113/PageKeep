import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class NotebookPresentation {
    var sheet: NotebookSheet?
    var notebookToDelete: Notebook?
    var notebookToAddPages: UUID?
    var errorMessage: String?
    private(set) var isPerformingAction = false
    private var requestID: UUID?
    private var shareTask: Task<Void, Never>?
    private var destination: NotebookDestination?
    private var pendingShareError: String?

    func show(_ kind: NotebookSheet.Kind) {
        guard requestID == nil, !isPerformingAction else { return }
        let request = NotebookSheet(kind: kind)
        requestID = request.id
        sheet = request
    }

    func chooseAcquisition(_ notebookID: UUID, source: AcquisitionSource) {
        notebookToAddPages = nil
        show(.acquisition(notebookID, source))
    }

    func finish(opening notebookID: UUID? = nil, pageID: UUID? = nil, requestID: UUID? = nil) {
        guard let activeID = self.requestID, requestID == nil || requestID == activeID else { return }
        destination = notebookID.map { NotebookDestination(notebookID: $0, pageID: pageID) }
        sheet = nil
    }

    @discardableResult
    func didDismiss() -> NotebookDestination? {
        let next = destination
        destination = nil
        requestID = nil
        shareTask = nil
        if let pendingShareError {
            errorMessage = pendingShareError
            self.pendingShareError = nil
        }
        return next
    }

    func cancelPreparation() {
        guard sheet == nil, destination == nil else { return }
        requestID = nil
        shareTask?.cancel()
        shareTask = nil
    }

    func archive(_ id: UUID, store: LibraryStore) {
        perform(store: store) { try await store.setArchived(true, ids: [id]) }
    }

    func delete(_ id: UUID, store: LibraryStore) {
        perform(store: store) { try await store.deleteNotebook(id) }
    }

    private func perform(store: LibraryStore, operation: @escaping () async throws -> Void) {
        guard !isPerformingAction, !store.isBusy, requestID == nil else { return }
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func share(_ notebook: Notebook, store: LibraryStore) {
        guard requestID == nil, !isPerformingAction, !store.isBusy else { return }
        let token = UUID()
        requestID = token
        shareTask = Task {
            guard requestID == token, !Task.isCancelled else { return }
            do {
                let url = try await store.shareCopy(of: notebook.id)
                guard requestID == token, !Task.isCancelled else {
                    ShareFileCleanup.remove(url)
                    return
                }
                sheet = NotebookSheet(id: token, kind: .share(url))
            } catch {
                guard requestID == token else { return }
                requestID = nil
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            shareTask = nil
        }
    }

    func shareFailed(_ error: Error, requestID: UUID) {
        guard self.requestID == requestID else { return }
        pendingShareError = "The PDF could not be shared. Please try Share PDF again. \(error.localizedDescription)"
    }
}

struct NotebookDestination {
    let notebookID: UUID
    let pageID: UUID?
}

struct NotebookSheet: Identifiable {
    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    enum Kind {
        case acquisition(UUID?, AcquisitionSource)
        case manage(UUID)
        case edit(UUID)
        case settings
        case share(URL)
    }
}

struct NotebookMenuActions: View {
    let store: LibraryStore
    let notebook: Notebook
    let presentation: NotebookPresentation

    var body: some View {
        Button("Edit Notebook", systemImage: "pencil") {
            presentation.show(.edit(notebook.id))
        }
        Menu("Add Pages", systemImage: "doc.badge.plus") {
            Button("Scan Pages", systemImage: "doc.viewfinder") {
                presentation.show(.acquisition(notebook.id, .scan))
            }
            Button("Import PDF", systemImage: "doc.badge.plus") {
                presentation.show(.acquisition(notebook.id, .importPDF))
            }
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
        Button("Archive", systemImage: "archivebox") {
            presentation.archive(notebook.id, store: store)
        }
        Button(role: .destructive) {
            presentation.notebookToDelete = notebook
        } label: {
            PermanentDeleteLabel()
        }
    }
}

struct PermanentDeleteLabel: View {
    var body: some View {
        Label {
            Text("Delete Permanently")
        } icon: {
            if let trash = UIImage(systemName: "trash") {
                // Keep native menus from tinting the icon with the surrounding menu color.
                Image(uiImage: trash.withTintColor(.systemRed, renderingMode: .alwaysOriginal))
            }
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
                if let destination = presentation.didDismiss() {
                    onOpen(destination.notebookID, destination.pageID)
                }
            }) { sheet in
                switch sheet.kind {
                case let .acquisition(id, source):
                    AcquisitionView(
                        store: store,
                        purpose: id.map(AcquisitionPurpose.append) ?? .createNotebook,
                        initialSource: source
                    ) { result in
                        if case let .saved(saved) = result {
                            presentation.finish(opening: saved.notebookID, pageID: saved.firstAddedPageID, requestID: sheet.id)
                        }
                    }
                case let .manage(id):
                    NavigationStack {
                        PageManagementView(store: store, notebookID: id) { pageID in
                            presentation.finish(opening: id, pageID: pageID, requestID: sheet.id)
                        }
                    }
                case let .edit(id):
                    NotebookEditorView(store: store, notebookID: id) { id, pageID in
                        presentation.finish(opening: pageID == nil ? nil : id, pageID: pageID, requestID: sheet.id)
                    }
                case .settings:
                    SettingsView(store: store)
                case let .share(url):
                    ShareSheet(url: url) { error in
                        presentation.shareFailed(error, requestID: sheet.id)
                    }
                }
            }
            .confirmationDialog("Add Pages", isPresented: Binding(
                get: { presentation.notebookToAddPages != nil },
                set: { if !$0 { presentation.notebookToAddPages = nil } }
            ), titleVisibility: .visible) {
                if let id = presentation.notebookToAddPages {
                    Button("Scan Pages") { presentation.chooseAcquisition(id, source: .scan) }
                    Button("Import PDF") { presentation.chooseAcquisition(id, source: .importPDF) }
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog(
                "Permanently delete “\(presentation.notebookToDelete?.name ?? "Notebook")”?",
                isPresented: Binding(
                    get: { presentation.notebookToDelete != nil },
                    set: { if !$0 { presentation.notebookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let notebook = presentation.notebookToDelete {
                    if !notebook.isArchived {
                        Button("Archive") { presentation.archive(notebook.id, store: store) }
                    }
                    Button("Delete Permanently", role: .destructive) {
                        presentation.delete(notebook.id, store: store)
                    }
                }
                Button("Cancel", role: .cancel) { presentation.notebookToDelete = nil }
            } message: {
                Text(presentation.notebookToDelete?.isArchived == true
                    ? "You can keep this notebook archived and bring it back anytime."
                    : "You can archive notebooks and bring them back anytime.")
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
