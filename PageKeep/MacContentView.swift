import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    let store: LibraryStore
    @Environment(AppSettings.self) private var settings
    @Environment(ReadingPositionStore.self) private var positions
    @Environment(FolderExpansionStore.self) private var folderExpansion
    @State private var notebookID: UUID?
    @State private var requestedPageID: UUID?
    @State private var selectionRequestID = UUID()
    @State private var readerSession = ReaderSession()
    @State private var currentPage = 1
    @State private var searchText = ""
    @State private var showsArchive = false
    @State private var showsSettings = false
    @State private var editor: MacEditorSession?
    @State private var managingID: UUID?
    @State private var notebookToDelete: Notebook?
    @State private var folderToRename: NotebookFolder?
    @State private var folderToDelete: NotebookFolder?
    @State private var showsFolderPrompt = false
    @State private var folderName = ""
    @State private var errorMessage: String?
    @State private var preparing = false
    @State private var performingAction = false
    @State private var appendSession: MacAppendSession?
    @State private var confirmRecovery = false
    @State private var selectedArchive: Set<UUID> = []
    @State private var importTask: Task<Void, Never>?
    @State private var importGeneration = UUID()

    private var notebook: Notebook? { notebookID.flatMap(store.notebook) }
    private var visibleNotebooks: [Notebook] {
        NotebookSearch.results(
            in: showsArchive ? store.archivedNotebooks : store.activeNotebooks, query: searchText
        )
    }
    private var isBlocked: Bool { store.isBusy || preparing || performingAction || editor != nil || managingID != nil || appendSession != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let notebook { reader(notebook) } else { library }
            }
            .navigationTitle(notebook?.name ?? (showsArchive ? "Archive" : "PageKeep"))
            .toolbar { toolbar }
        }
        .disabled(isBlocked)
        .frame(minWidth: 640, minHeight: 480)
        .task { await store.load() }
        .sheet(item: $editor) { session in
            MacNotebookEditor(store: store, session: session) { saved in
                if let savedNotebook = store.notebook(id: saved.notebookID),
                   let folderID = store.effectiveFolderID(for: savedNotebook),
                   session.notebookID == nil || session.draft.baseNotebook?.folderID != folderID {
                    folderExpansion.setExpanded(true, for: folderID)
                }
                editor = nil
                notebookID = saved.notebookID
                requestedPageID = saved.firstAddedPageID
                selectionRequestID = UUID()
            }
        }
        .sheet(item: $appendSession) { session in
            MacAppendConfirmation(store: store, session: session) { saved in
                appendSession = nil
                if let saved {
                    notebookID = saved.notebookID
                    requestedPageID = saved.firstAddedPageID
                    selectionRequestID = UUID()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { managingID != nil }, set: { if !$0 { managingID = nil } }
        )) {
            if let managingID {
                MacPageManagement(store: store, notebookID: managingID) { requestedPageID = $0; selectionRequestID = UUID() }
            }
        }
        .sheet(isPresented: $showsSettings) { MacSettingsView(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PageKeep.showSettings"))) { _ in
            if !isBlocked { showsSettings = true }
        }
        .onDrop(of: [UTType.item.identifier], isTargeted: nil, perform: receiveDrop)
        .alert("Couldn’t Complete Action", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
        .alert(folderToRename == nil ? "Create Folder" : "Rename Folder", isPresented: $showsFolderPrompt) {
            TextField("Folder Name", text: $folderName)
            Button("Cancel", role: .cancel) { folderToRename = nil }
            Button(folderToRename == nil ? "Create" : "Save") { saveFolder() }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete “\(folderToDelete?.name ?? "Folder")”?",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let folder = folderToDelete {
                Button("Delete Folder", role: .destructive) {
                    perform { try await store.deleteFolder(folder.id) }
                }
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: { Text("Your notebooks will be kept in the library without a folder.") }
        .confirmationDialog(
            "Permanently delete “\(notebookToDelete?.name ?? "Notebook")”?",
            isPresented: Binding(get: { notebookToDelete != nil }, set: { if !$0 { notebookToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let target = notebookToDelete {
                if !target.isArchived {
                    Button("Archive") {
                        perform { try await store.setArchived(true, ids: [target.id]); notebookID = nil }
                    }
                }
                Button("Delete Permanently", role: .destructive) {
                    perform {
                        try await store.deleteNotebook(target.id)
                        if notebookID == target.id { notebookID = nil }
                    }
                }
            }
            Button("Cancel", role: .cancel) { notebookToDelete = nil }
        } message: { Text("You can archive a notebook and restore it later instead.") }
        .confirmationDialog("Recover Library Backup?", isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button("Recover Backup") { Task { await store.recover() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This replaces the current library with the last complete saved backup. Your saved PDF files are kept.") }
        .background(MacWindowCloseGuard())
        .onChange(of: searchText) { _, _ in selectedArchive = [] }
        .onChange(of: isBlocked) { _, _ in updateDraftProtection() }
        .onChange(of: store.isBusy) { _, _ in updateDraftProtection() }
        .onChange(of: editor?.hasPendingChanges) { _, _ in updateDraftProtection() }
        .onChange(of: editor?.draft.isSaving) { _, _ in updateDraftProtection() }
        .onChange(of: editor?.id) { _, _ in updateDraftProtection() }
        .onChange(of: appendSession?.id) { _, _ in updateDraftProtection() }
        .onDisappear {
            importGeneration = UUID()
            importTask?.cancel()
            if let editor { Task { await editor.discard(in: store.repository) } }
            if let appendSession { Task { await store.repository.discardPrepared(appendSession.prepared) } }
        }
    }

    private var library: some View {
        Group {
            if store.isLoading { ProgressView("Loading Notebooks…") }
            else if let error = store.loadError {
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await store.reload() } }
                    if store.canRecover { Button("Recover Backup") { confirmRecovery = true } }
                }
            } else if visibleNotebooks.isEmpty && (showsArchive || !searchText.isEmpty || store.folders.isEmpty) {
                ContentUnavailableView(
                    searchText.isEmpty ? (showsArchive ? "No Archived Notebooks" : "No Notebooks") : "No Matching Notebooks",
                    systemImage: searchText.isEmpty ? "book.closed" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Import a PDF or create a notebook to get started." : "Try a different notebook name.")
                )
            } else {
                List(selection: $selectedArchive) {
                    if showsArchive || !searchText.isEmpty {
                        ForEach(visibleNotebooks) { notebook in
                            libraryNotebookRow(notebook)
                        }
                    } else {
                        ForEach(store.rootItems) { item in
                            switch item {
                            case .folder(let folder):
                                folderRow(folder)
                            case .notebook(let notebook):
                                libraryNotebookRow(notebook)
                            }
                        }
                        .onMove { source, destination in
                            reorderItems(store.rootItems.map(\.id), from: source, to: destination, in: nil)
                        }
                        .moveDisabled(isBlocked)
                    }
                }
                .disabled(isBlocked)
            }
        }
        .searchable(text: $searchText, prompt: "Search Notebooks")
    }

    private func libraryNotebookRow(_ notebook: Notebook) -> some View {
        Group {
            if showsArchive {
                notebookRow(notebook)
            } else {
                Button { open(notebook) } label: { notebookRow(notebook) }
                    .buttonStyle(.plain)
            }
        }
        .tag(notebook.id)
        .padding(.vertical, 4)
        .contextMenu { notebookMenu(notebook) }
    }

    private func folderRow(_ folder: NotebookFolder) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { folderExpansion.isExpanded(folder.id) },
            set: { folderExpansion.setExpanded($0, for: folder.id) }
        )) {
            ForEach(store.notebooks(in: folder.id)) { notebook in
                libraryNotebookRow(notebook)
            }
            .onMove { source, destination in
                reorderItems(store.notebooks(in: folder.id).map(\.id), from: source, to: destination, in: folder.id)
            }
            .moveDisabled(isBlocked)
        } label: {
            Label(folder.name, systemImage: "folder")
                .font(.headline)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename Folder", systemImage: "pencil") { promptForFolder(folder) }
                    Button("Move Up", systemImage: "arrow.up") { moveItem(folder.id, in: nil, by: -1) }
                    Button("Move Down", systemImage: "arrow.down") { moveItem(folder.id, in: nil, by: 1) }
                    Button("Delete Folder", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                }
        }
    }

    private func promptForFolder(_ folder: NotebookFolder? = nil) {
        folderToRename = folder
        folderName = folder?.name ?? ""
        showsFolderPrompt = true
    }

    private func saveFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderToRename
        perform {
            if let folder {
                try await store.renameFolder(folder.id, name: name)
            } else {
                let id = try await store.createFolder(name: name)
                folderExpansion.setExpanded(true, for: id)
            }
        }
    }

    private func open(_ notebook: Notebook) {
        guard !isBlocked else { return }
        notebookID = notebook.id
        requestedPageID = nil
        currentPage = 1
        selectionRequestID = UUID()
        readerSession = ReaderSession()
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        HStack(spacing: 12) {
            NotebookIcon(notebook: notebook)
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.name).font(.headline)
                HStack(spacing: 6) {
                    Text(notebook.pageCountLabel)
                    if (showsArchive || !searchText.isEmpty), let folderName = store.folderName(for: notebook) {
                        Text("· \(folderName)")
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.notebookErrors[notebook.id] != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if showsArchive {
                Button("Open") { open(notebook) }.buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func reader(_ notebook: Notebook) -> some View {
        if let error = store.notebookErrors[notebook.id] {
            ContentUnavailableView("PDF Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let url = store.pdfURL(for: notebook), !notebook.pages.isEmpty {
            MacPDFReader(
                url: url, notebook: notebook, requestedPageID: requestedPageID,
                readingMode: settings.readingMode, positions: positions,
                onPageChange: { currentPage = $0 }, session: readerSession, selectionRequestID: selectionRequestID
            )
            .overlay(alignment: .bottom) {
                if settings.showsPageNumber {
                    Text("\(currentPage) of \(notebook.pageCount)")
                        .font(.caption).monospacedDigit().padding(8)
                        .background(.regularMaterial, in: Capsule()).padding()
                }
            }
        } else {
            ContentUnavailableView("No Pages Yet", systemImage: "doc", description: Text("Use Add Pages to import a PDF."))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let notebook {
            ToolbarItem(placement: .navigation) {
                Button("Library", systemImage: "chevron.left") { notebookID = nil; requestedPageID = nil }
            }
            ToolbarItemGroup {
                Button("Add Pages", systemImage: "doc.badge.plus") { edit(notebook, importing: true) }
                Button("Manage Pages", systemImage: "square.grid.2x2") { managingID = notebook.id }
                    .disabled(notebook.pages.isEmpty || store.notebookErrors[notebook.id] != nil)
                Button("Save PDF", systemImage: "square.and.arrow.down") { export(notebook) }
                    .disabled(notebook.pages.isEmpty || store.notebookErrors[notebook.id] != nil)
                MacShareButton(store: store, notebookID: notebook.id) { errorMessage = $0 }
                    .disabled(notebook.pages.isEmpty || store.notebookErrors[notebook.id] != nil)
                Menu {
                    notebookMenu(notebook)
                } label: { Label("Notebook Actions", systemImage: "ellipsis.circle") }
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button(showsArchive ? "Library" : "Archive", systemImage: showsArchive ? "books.vertical" : "archivebox") {
                    showsArchive.toggle()
                    selectedArchive = []
                }
            }
            ToolbarItemGroup {
                if preparing { ProgressView().controlSize(.small) }
                Button("Import PDF", systemImage: "square.and.arrow.down") {
                    if let url = MacFileActions.choosePDF() { stage(url) }
                }
                Menu {
                    Button("Import PDF", systemImage: "square.and.arrow.down") {
                        if let url = MacFileActions.choosePDF() { stage(url) }
                    }
                    Button("Create Folder", systemImage: "folder.badge.plus") { promptForFolder() }
                } label: { Label("New", systemImage: "plus") }
                if showsArchive {
                    Button("Restore Selected", systemImage: "arrow.uturn.backward") {
                        let ids = selectedArchive
                        perform { try await store.setArchived(false, ids: ids); selectedArchive = [] }
                    }
                    .disabled(selectedArchive.isEmpty)
                    Button("Restore All") {
                        perform { try await store.setArchived(false, ids: Set(store.archivedNotebooks.map(\.id))); selectedArchive = [] }
                    }
                    .disabled(store.archivedNotebooks.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func notebookMenu(_ notebook: Notebook) -> some View {
        Button("Edit Notebook", systemImage: "pencil") { edit(notebook) }
        MoveToFolderMenu(store: store, notebook: notebook) { errorMessage = $0 }
        Button(notebook.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
            perform {
                try await store.setArchived(!notebook.isArchived, ids: [notebook.id])
                notebookID = nil
            }
        }
        if !notebook.isArchived && searchText.isEmpty {
            Button("Move Up", systemImage: "arrow.up") { moveItem(notebook.id, in: store.effectiveFolderID(for: notebook), by: -1) }
            Button("Move Down", systemImage: "arrow.down") { moveItem(notebook.id, in: store.effectiveFolderID(for: notebook), by: 1) }
        }
        Button("Delete Permanently", systemImage: "trash", role: .destructive) { notebookToDelete = notebook }
    }

    private func edit(_ notebook: Notebook, importing: Bool = false) {
        guard !isBlocked else { return }
        if importing {
            guard let url = MacFileActions.choosePDF() else { return }
            stage(url, appendingTo: notebook)
        } else {
            editor = MacEditorSession(notebookID: notebook.id, draft: NotebookDraft(details: notebook.details, existingNotebook: notebook, savedURL: store.pdfURL(for: notebook)))
        }
    }

    private func stage(_ url: URL, appendingTo notebook: Notebook? = nil) {
        guard !isBlocked else { errorMessage = "Finish the current change before importing another PDF."; return }
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            errorMessage = "Choose a PDF file to import."; return
        }
        preparing = true
        let generation = UUID()
        importGeneration = generation
        updateDraftProtection()
        importTask = Task {
            defer { if importGeneration == generation { preparing = false; importTask = nil } }
            do {
                let prepared = try await store.repository.prepareImport(from: url)
                guard !Task.isCancelled, importGeneration == generation else {
                    await store.repository.discardPrepared(prepared)
                    return
                }
                if let notebook {
                    appendSession = MacAppendSession(notebookID: notebook.id, prepared: prepared)
                    return
                }
                editor = MacEditorSession(
                    notebookID: notebook?.id,
                    draft: NotebookDraft(
                        details: notebook?.details ?? NotebookDetails(name: prepared.suggestedName),
                        additions: [prepared], existingNotebook: notebook, savedURL: notebook.flatMap(store.pdfURL)
                    )
                )
            } catch {
                if !Task.isCancelled, importGeneration == generation { errorMessage = error.localizedDescription }
            }
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBlocked, !showsSettings else { errorMessage = "Finish the current change before dropping another PDF."; return true }
        guard providers.count == 1 else { errorMessage = "Drop one PDF at a time."; return true }
        guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            errorMessage = "Drop a PDF file from Finder."; return true
        }
        preparing = true
        let generation = UUID()
        importGeneration = generation
        updateDraftProtection()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = nil }
            Task { @MainActor in
                guard importGeneration == generation else { return }
                preparing = false
                if let url { stage(url) }
                else { errorMessage = error?.localizedDescription ?? "Drop a PDF file from Finder." }
            }
        }
        return true
    }

    private func moveItem(_ id: UUID, in folderID: UUID?, by offset: Int) {
        var ids = folderID == nil ? store.rootItems.map(\.id) : store.notebooks(in: folderID).map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        perform { try await store.reorderItems(inFolderID: folderID, orderedIDs: ids) }
    }

    private func reorderItems(_ ids: [UUID], from source: IndexSet, to destination: Int, in folderID: UUID?) {
        var ordered = ids
        ordered.move(fromOffsets: source, toOffset: destination)
        perform { try await store.reorderItems(inFolderID: folderID, orderedIDs: ordered) }
    }

    private func export(_ notebook: Notebook) {
        perform {
            let source = try await store.shareCopy(of: notebook.id)
            defer { ShareFileCleanup.remove(source) }
            guard let destination = MacFileActions.chooseSaveDestination(name: notebook.name) else { return }
            try await MacFileActions.copyPDF(source, to: destination)
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !isBlocked else { return }
        performingAction = true
        Task {
            defer { performingAction = false }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func updateDraftProtection() {
        let draft = editor?.draft
        let session = editor
        let append = appendSession
        MacDraftProtection.shared.isSaving = store.isBusy || draft?.isSaving == true
        MacDraftProtection.shared.hasChanges = preparing || append != nil || session?.hasPendingChanges == true
        MacDraftProtection.shared.discard = {
            importGeneration = UUID()
            importTask?.cancel()
            importTask = nil
            preparing = false
            if let session { await session.discard(in: store.repository) }
            if let append { await store.repository.discardPrepared(append.prepared) }
            editor = nil
            appendSession = nil
        }
    }
}

struct MacSettingsView: View {
    let store: LibraryStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        VStack {
            Form {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("Reading Direction", selection: $settings.readingMode) {
                    ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Page Number", isOn: $settings.showsPageNumber)
                SyncSettingsSection(store: store)
            }
            .formStyle(.grouped)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).padding(.bottom)
        }
        .frame(width: 480, height: 500)
    }
}
