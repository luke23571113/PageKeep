import SwiftUI

struct NotebookEditorView: View {
    let store: LibraryStore
    let notebookID: UUID?
    let onSaved: (UUID, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NotebookDraft
    @State private var source: EditorSource?
    @State private var showsPageArrangement = false
    @State private var showsDiscardConfirmation = false
    @State private var errorMessage: String?
    @State private var sourcesAvailable = false
    @State private var isCompleting = false
    @State private var isPresentingChild = false

    init(
        store: LibraryStore,
        notebookID: UUID,
        onSaved: @escaping (UUID, UUID?) -> Void
    ) {
        self.store = store
        self.notebookID = notebookID
        self.onSaved = onSaved
        let notebook = store.notebook(id: notebookID)
        let details = notebook?.details ?? NotebookDetails(name: "Untitled Notebook")
        _draft = State(initialValue: NotebookDraft(details: details, existingNotebook: notebook))
    }

    init(store: LibraryStore, draft: NotebookDraft, onSaved: @escaping (UUID, UUID?) -> Void) {
        self.store = store
        self.notebookID = nil
        self.onSaved = onSaved
        _draft = State(initialValue: draft)
    }

    private var existingPageCount: Int {
        draft.pageCount - draft.pendingPageCount
    }

    private var pendingPageCount: Int { draft.pendingPageCount }
    private var isSaving: Bool { draft.isSaving || isCompleting }
    private var hasChanges: Bool { draft.hasChanges }
    private var canSave: Bool { resolvedName != nil && (notebookID != nil || draft.pageCount > 0) }
    private var canArrangePages: Bool {
        sourcesAvailable && draft.pageCount > 0 && !isSaving && !store.isBusy && !isPresentingChild
            && (notebookID.flatMap { store.notebookErrors[$0] } == nil)
    }

    private var previewRequest: DraftPreviewRequest {
        let notebook = notebookID.flatMap { store.notebook(id: $0) }
        return DraftPreviewRequest(
            pages: draft.pages, notebook: notebook,
            savedURL: notebook.flatMap { store.pdfURL(for: $0) }, additions: draft.additions
        )
    }

    private var resolvedName: String? {
        try? NotebookNaming.resolvedName(draft.details.name, in: store.notebooks, excluding: notebookID)
    }

    var body: some View {
        @Bindable var draft = draft
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        NotebookIcon(symbolName: draft.details.symbolName, colorID: draft.details.colorID)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(resolvedName ?? "Notebook").font(.headline)
                            Text("\(draft.pageCount) \(draft.pageCount == 1 ? "page" : "pages")")
                                .foregroundStyle(.secondary)
                            if pendingPageCount > 0 {
                                Text("\(existingPageCount) saved · \(pendingPageCount) pending")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        guard canArrangePages else { return }
                        isPresentingChild = true
                        showsPageArrangement = true
                    } label: {
                        Label("Arrange Pages", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("editor.arrangePages")
                    .disabled(!canArrangePages)
                } footer: {
                    Text("Reorder or remove pages before saving this notebook.")
                }
                Section("Name") {
                    TextField("Notebook name", text: $draft.details.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("editor.name")
                    if let resolvedName, resolvedName != draft.details.name.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Text("Will save as “\(resolvedName)”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if resolvedName == nil {
                        Text("Enter a notebook name to save.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                NotebookAppearancePicker(draft: draft)
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Retry Save", action: save)
                            .disabled(!canSave || store.isBusy)
                    }
                }
            }
            .contentMargins(.bottom, 88, for: .scrollContent)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 12) {
                    addPagesMenu
                    if isSaving { ProgressView("Saving…") }
                }
                .padding(16)
            }
            .navigationTitle(notebookID == nil ? "New Notebook" : "Edit Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: requestClose)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("editor.close")
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("editor.save")
                        .disabled(isSaving || store.isBusy || !canSave)
                }

            }
            .disabled(isSaving)
        }
        .task(id: previewRequest) {
            sourcesAvailable = false
            let request = previewRequest
            let available = await Task.detached(priority: .userInitiated) { request.sourcesExist() }.value
            guard !Task.isCancelled else { return }
            sourcesAvailable = available
        }
        .sheet(item: $source, onDismiss: { isPresentingChild = false }) { source in
            AcquisitionView(
                store: store,
                purpose: .draft,
                initialSource: source.source
            ) { result in
                if case let .prepared(prepared) = result { draft.add(prepared) }
            }
        }
        .fullScreenCover(isPresented: $showsPageArrangement, onDismiss: {
            isPresentingChild = false
            refreshSources()
        }) {
            DraftPageArrangementView(store: store, notebookID: notebookID, draft: draft)
        }
        .background {
            DraftDismissalGuard(isBlocked: hasChanges || isSaving, onAttempt: requestClose)
        }
        .confirmationDialog("Discard changes?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { discardAndClose() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your changes and any pending pages will be discarded.")
        }
    }

    @ViewBuilder
    private var addPagesMenu: some View {
        let menu = Menu {
            AcquisitionMenuChoices(onChoose: addPages)
        } label: {
            Label("Add Pages", systemImage: "doc.badge.plus")
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("editor.addPages")
        .disabled(isSaving || isPresentingChild || store.isBusy || (notebookID.map { store.notebookErrors[$0] != nil } ?? false))
        .tint(.primary)

        if #available(iOS 26.0, *) {
            menu
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            menu
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private func addPages(from source: AcquisitionSource) {
        guard !isSaving, !isPresentingChild, !store.isBusy else { return }
        isPresentingChild = true
        self.source = EditorSource(source: source)
    }

    private func refreshSources() {
        let request = previewRequest
        Task {
            let available = await Task.detached(priority: .userInitiated) { request.sourcesExist() }.value
            guard request == previewRequest else { return }
            sourcesAvailable = available
        }
    }

    private func requestClose() {
        guard !isSaving, !isPresentingChild else { return }
        if hasChanges {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func discardAndClose() {
        guard !isSaving else { return }
        isCompleting = true
        Task { await draft.discardPendingPages(in: store.repository) }
        dismiss()
    }

    private func save() {
        guard !isSaving, !isPresentingChild, !store.isBusy, canSave else { return }
        isCompleting = true
        errorMessage = nil
        Task {
            do {
                let result = try await draft.save(in: store, notebookID: notebookID)
                onSaved(result.notebookID, result.firstAddedPageID)
            } catch {
                isCompleting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EditorSource: Identifiable {
    let id = UUID()
    let source: AcquisitionSource
}

private struct NotebookAppearancePicker: View {
    @Bindable var draft: NotebookDraft

    var body: some View {
        symbolSection
        colorSection
    }

    var symbolSection: some View {
        Section("Symbol") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                ForEach(NotebookAppearance.symbols) { symbol in
                    Button {
                        draft.details.symbolName = symbol.id
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: NotebookAppearance.symbol(symbol.id)).font(.title2)
                            Text(symbol.title).font(.caption)
                            Image(systemName: draft.details.symbolName == symbol.id ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.details.symbolName == symbol.id ? Color.accentColor : Color.primary)
                    .accessibilityLabel(symbol.title)
                    .accessibilityAddTraits(draft.details.symbolName == symbol.id ? .isSelected : [])
                    .accessibilityIdentifier("editor.symbol.\(symbol.id)")
                }
            }
        }
    }

    var colorSection: some View {
        Section("Color") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                ForEach(NotebookAppearance.colors) { color in
                    Button {
                        draft.details.colorID = color.id
                    } label: {
                        VStack(spacing: 6) {
                            Circle().fill(color.color).frame(width: 28, height: 28)
                            Text(color.title).font(.caption)
                            Image(systemName: draft.details.colorID == color.id ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(draft.details.colorID == color.id ? .isSelected : [])
                    .accessibilityIdentifier("editor.color.\(color.id)")
                }
            }
        }
    }

}
