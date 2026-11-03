import SwiftUI
import PDFKit
import Observation

@MainActor
@Observable
final class MacEditorSession: Identifiable {
    let id = UUID()
    let notebookID: UUID?
    let draft: NotebookDraft
    private(set) var isImporting = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = UUID()

    init(notebookID: UUID?, draft: NotebookDraft) {
        self.notebookID = notebookID
        self.draft = draft
    }

    var hasPendingChanges: Bool { isImporting || draft.hasChanges }

    @discardableResult
    func importPDF(
        from url: URL, in repository: LibraryRepository,
        onError: @escaping (String) -> Void
    ) -> Task<Void, Never>? {
        guard !isImporting, !draft.isSaving else { return nil }
        isImporting = true
        let generation = UUID()
        importGeneration = generation
        let task = Task {
            defer {
                if importGeneration == generation {
                    isImporting = false
                    importTask = nil
                }
            }
            do {
                let prepared = try await repository.prepareImport(from: url)
                guard !Task.isCancelled, importGeneration == generation else {
                    await repository.discardPrepared(prepared)
                    return
                }
                draft.add(prepared)
            } catch {
                if !Task.isCancelled, importGeneration == generation { onError(error.localizedDescription) }
            }
        }
        importTask = task
        return task
    }

    func cancelImport() {
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
    }

    func discard(in repository: LibraryRepository) async {
        cancelImport()
        await draft.discardPendingPages(in: repository)
    }
}

struct MacNotebookEditor: View {
    let store: LibraryStore
    let session: MacEditorSession
    let onSaved: (SavedNotebook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPages: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @State private var arranging = false
    @State private var saveRequested = false

    var body: some View {
        @Bindable var draft = session.draft
        let sources = DraftPagePreviewSources(
            notebook: draft.baseNotebook, savedURL: draft.pinnedPDFURL, additions: draft.additions
        )
        VStack(spacing: 0) {
            HStack {
                Text(session.notebookID == nil ? "New Notebook" : "Edit Notebook").font(.headline)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(draft.details.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            Divider()
            Form {
                TextField("Name", text: $draft.details.name)
                Picker("Symbol", selection: $draft.details.symbolName) {
                    ForEach(NotebookAppearance.symbols) { symbol in
                        Label(symbol.title, systemImage: symbol.id).tag(symbol.id)
                    }
                }
                Picker("Color", selection: $draft.details.colorID) {
                    ForEach(NotebookAppearance.colors) { color in
                        Text(color.title).tag(color.id)
                    }
                }
                Section("Folder") {
                    FolderPicker(store: store, selection: $draft.details.folderID)
                }
                HStack {
                    Text("\(draft.pageCount) pages")
                    Spacer()
                    Button("Add PDF", systemImage: "doc.badge.plus", action: importPDF)
                    Toggle("Arrange Pages", isOn: $arranging).toggleStyle(.button)
                }
            }
            .formStyle(.grouped)
            if arranging {
                List(selection: $selectedPages) {
                    ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                        HStack {
                            if let source = sources.source(for: page) {
                                MacPageThumbnail(source: source)
                            }
                            Text("Page \(index + 1)")
                            if case .prepared = page.source { Text("Added").foregroundStyle(.secondary) }
                        }
                        .tag(page.id)
                    }
                }
                .frame(minHeight: 160)
                HStack {
                    Button("Move Up", systemImage: "arrow.up") { move(-1) }
                    Button("Move Down", systemImage: "arrow.down") { move(1) }
                    Spacer()
                    Button("Remove", systemImage: "trash") {
                        do {
                            try draft.removePages(ids: selectedPages)
                            selectedPages = []
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(selectedPages.isEmpty)
                .padding()
            }
            if draft.isSaving || session.isImporting { ProgressView().padding() }
        }
        .frame(width: 540, height: arranging ? 730 : 430)
        .disabled(draft.isSaving || session.isImporting || saveRequested)
        .interactiveDismissDisabled(session.hasPendingChanges || draft.isSaving)
        .onDisappear { session.cancelImport() }
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: discard)
            Button("Keep Editing", role: .cancel) { }
        }
        .alert("Couldn’t Complete Action", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func cancel() {
        if session.draft.hasChanges { confirmDiscard = true } else { discard() }
    }

    private func discard() {
        Task {
            await session.discard(in: store.repository)
            dismiss()
        }
    }

    private func save() {
        guard !saveRequested else { return }
        saveRequested = true
        Task {
            defer { saveRequested = false }
            do { onSaved(try await session.draft.save(in: store, notebookID: session.notebookID)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func importPDF() {
        guard let url = MacFileActions.choosePDF() else { return }
        session.importPDF(from: url, in: store.repository) { errorMessage = $0 }
    }

    private func move(_ offset: Int) {
        let ids = session.draft.pages.map(\.id)
        do { try session.draft.reorderPages(orderedIDs: MacPageOrder.moved(ids, selection: selectedPages, offset: offset)) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct MacPageManagement: View {
    let store: LibraryStore
    let notebookID: UUID
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var performingAction = false

    private var notebook: Notebook? { store.notebook(id: notebookID) }

    var body: some View {
        VStack {
            HStack {
                Text("Manage Pages").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            List(selection: $selection) {
                ForEach(Array((notebook?.pages ?? []).enumerated()), id: \.element.id) { index, page in
                    HStack {
                        if let notebook, let url = store.pdfURL(for: notebook) {
                            MacPageThumbnail(source: DraftPagePreviewSource(url: url, pageIndex: index))
                        }
                        Text("Page \(index + 1)")
                        Spacer()
                        Button("Open") { onOpen(page.id); dismiss() }.buttonStyle(.borderless)
                    }
                    .tag(page.id)
                }
            }
            HStack {
                Button("Move Up", systemImage: "arrow.up") { move(-1) }
                Button("Move Down", systemImage: "arrow.down") { move(1) }
                Button("Rotate", systemImage: "rotate.right") {
                    perform { try await store.rotatePages(in: notebookID, ids: selection) }
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
            .disabled(selection.isEmpty || store.isBusy || performingAction)
            .padding()
        }
        .frame(width: 560, height: 540)
        .disabled(store.isBusy || performingAction)
        .confirmationDialog("Delete selected pages?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Pages", role: .destructive) {
                let ids = selection
                perform { try await store.deletePages(in: notebookID, ids: ids); selection = [] }
            }
        } message: { Text("This permanently removes the selected pages from the saved notebook.") }
        .alert("Couldn’t Complete Action", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func move(_ offset: Int) {
        guard let pages = notebook?.pages else { return }
        let ids = MacPageOrder.moved(pages.map(\.id), selection: selection, offset: offset)
        perform { try await store.reorderPages(in: notebookID, orderedIDs: ids) }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !performingAction, !store.isBusy else { return }
        performingAction = true
        Task {
            defer { performingAction = false }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct MacAppendSession: Identifiable {
    let id = UUID()
    let notebookID: UUID
    let prepared: PreparedPDF
}

struct MacAppendConfirmation: View {
    let store: LibraryStore
    let session: MacAppendSession
    let onFinish: (SavedNotebook?) -> Void
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Pages").font(.headline)
            Text("Add \(session.prepared.pageCount) pages to “\(store.notebook(id: session.notebookID)?.name ?? "Notebook")”?")
            HStack {
                Button("Discard", role: .cancel) {
                    Task { await store.repository.discardPrepared(session.prepared); onFinish(nil) }
                }
                Button("Add \(session.prepared.pageCount) Pages") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let result = try await store.appendPrepared(session.prepared, to: session.notebookID)
                            await store.repository.discardPrepared(session.prepared)
                            onFinish(result)
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            if saving { ProgressView() }
        }
        .padding(28)
        .frame(width: 440)
        .disabled(saving || store.isBusy)
        .interactiveDismissDisabled()
        .alert("Couldn’t Add Pages", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "Please try again.") }
    }
}

private enum MacPageOrder {
    static func moved(_ ids: [UUID], selection: Set<UUID>, offset: Int) -> [UUID] {
        guard let first = ids.firstIndex(where: { selection.contains($0) }),
              let last = ids.lastIndex(where: { selection.contains($0) }) else { return ids }
        let selected = ids.filter { selection.contains($0) }
        var remaining = ids.filter { !selection.contains($0) }
        let destination = offset < 0 ? max(0, first - 1) : min(remaining.count, last - selected.count + 2)
        remaining.insert(contentsOf: selected, at: destination)
        return remaining
    }
}

private struct MacPageThumbnail: View {
    let source: DraftPagePreviewSource
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .frame(width: 64, height: 84)
        .accessibilityHidden(true)
        .task(id: "\(source.url.absoluteString)-\(source.pageIndex)") {
            image = nil
            let result = await MacThumbnailCache.shared.image(source: source)
            guard !Task.isCancelled else { return }
            image = result.image
        }
    }
}

private struct MacThumbnailImage: @unchecked Sendable {
    let image: NSImage?
}

private actor MacThumbnailCache {
    static let shared = MacThumbnailCache()
    private let images = NSCache<NSString, NSImage>()
    private let documents = NSCache<NSURL, PDFDocument>()

    init() {
        images.countLimit = 100
        images.totalCostLimit = 16 * 1024 * 1024
        documents.countLimit = 4
    }

    func image(source: DraftPagePreviewSource) -> MacThumbnailImage {
        let key = "\(source.url.path)#\(source.pageIndex)" as NSString
        if let image = images.object(forKey: key) { return MacThumbnailImage(image: image) }
        guard !Task.isCancelled else { return MacThumbnailImage(image: nil) }
        return autoreleasepool {
            let document = documents.object(forKey: source.url as NSURL) ?? PDFDocument(url: source.url)
            guard let document, let page = document.page(at: source.pageIndex) else { return MacThumbnailImage(image: nil) }
            documents.setObject(document, forKey: source.url as NSURL)
            let image = page.thumbnail(of: CGSize(width: 128, height: 168), for: .mediaBox)
            images.setObject(image, forKey: key, cost: 128 * 168 * 4)
            return MacThumbnailImage(image: image)
        }
    }
}
