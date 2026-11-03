import SwiftUI
import Observation

struct ContentView: View {
    let store: LibraryStore
    @State private var navigation = LibraryNavigation()
    @State private var presentation = NotebookPresentation()
    @State private var showsRecoveryConfirmation = false
    @State private var searchText = ""
    @State private var isSavingOrder = false
    @State private var showsSearch = false
    @State private var searchPull = SearchPullState()
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showsFolderName = false
    @State private var folderName = ""
    @State private var folderToRename: UUID?
    @State private var folderToDelete: NotebookFolder?
    @Environment(FolderExpansionStore.self) private var folderExpansion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { store.isBusy || isSavingOrder }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isPad {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    libraryContent
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 380)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Settings", systemImage: "gearshape") { presentation.show(.settings) }
                                    .accessibilityIdentifier("library.settings")
                            }
                            ToolbarItem(placement: .topBarTrailing) { createNotebookMenu.disabled(isBusy || store.loadError != nil) }
                        }
                        .searchable(text: $searchText, prompt: "Search Notebooks")
                } detail: {
                    NavigationStack {
                        if let id = navigation.path.last {
                            reader(id)
                                .id(id)
                        } else {
                            ContentUnavailableView("Select a Notebook", systemImage: "book.closed")
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                phoneNavigation
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isPad && navigation.path.isEmpty {
                createNotebookMenu
                    .modifier(LibraryCircleButton())
                    .disabled(isBusy || store.loadError != nil)
                    .padding(.trailing, 24)
                    .padding(.top, 10)
            }
        }
        .overlay(alignment: .top) {
            if !isPad && navigation.path.isEmpty && searchPull.isPulling && searchPull.distance > 8 {
                SearchPullIndicator(progress: min(searchPull.distance / 72, 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .offset(y: 10)
                    .allowsHitTesting(false)
            }
        }
        .notebookPresentations(store: store, presentation: presentation) { id, pageID in
            openNotebook(id, pageID: pageID)
        }
        .alert(folderToRename == nil ? "Create Folder" : "Rename Folder", isPresented: $showsFolderName) {
            TextField("Folder name", text: $folderName)
                .accessibilityIdentifier("folder.name")
            Button("Cancel", role: .cancel) { }
            Button(folderToRename == nil ? "Create" : "Save", action: saveFolderName)
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
        }
        .confirmationDialog("Delete “\(folderToDelete?.name ?? "Folder")”?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive, action: deleteFolder)
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Your notebooks will be kept and moved to No Folder.")
        }
        .task { await store.load() }
        .onChange(of: navigation.path) { _, _ in
            presentation.cancelPreparation()
            searchPull.reset(includingBaseline: true)
        }
        .onChange(of: store.rootItems.first?.id) { _, _ in
            searchPull.reset(includingBaseline: true)
        }
        .onDisappear {
            searchPull.reset()
            presentation.cancelPreparation()
        }
    }

    private var phoneNavigation: some View {
        @Bindable var navigation = navigation
        return NavigationStack(path: $navigation.path) {
            libraryContent
                .overlay(alignment: .bottomLeading) { settingsButton.padding(16) }
                .navigationDestination(for: UUID.self) { id in reader(id) }
        }
    }

    private var libraryContent: some View {
        Group {
            if store.isLoading {
                ProgressView("Loading notebooks…")
            } else if let error = store.loadError {
                storageError(error)
            } else if store.rootItems.isEmpty {
                emptyLibrary
            } else {
                notebookList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Notebooks")
    }

    private func reader(_ id: UUID) -> some View {
        NotebookView(
            store: store,
            notebookID: id,
            initialPageID: navigation.requestedPageID,
            selectionRequestID: navigation.selectionRequestID,
            presentation: presentation,
            session: navigation.readerSession,
            onClose: isPad ? { navigation.path = []; compactColumn = .sidebar } : nil
        )
    }

    private func openNotebook(_ id: UUID, pageID: UUID? = nil) {
        navigation.open(id, pageID: pageID)
        if isPad { compactColumn = .detail }
    }

    private var settingsButton: some View {
        Button {
            presentation.show(.settings)
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
        }
        .accessibilityIdentifier("library.settings")
        .modifier(LibraryCircleButton())
    }

    private var searchField: some View {
        HStack(spacing: 0) {
            LibrarySearchBar(text: $searchText, focusRequested: $showsSearch)
            Button("Cancel", action: closeSearch)
                .frame(minHeight: 44)
                .padding(.trailing, 8)
        }
        .frame(height: 44)
    }

    private var hasQuery: Bool { !NotebookSearch.normalized(searchText).isEmpty }

    private var displayedNotebooks: [Notebook] {
        NotebookSearch.results(in: store.activeNotebooks, query: searchText)
    }

    private var notebookList: some View {
        ScrollViewReader { scroll in
            List {
                if !isPad && (showsSearch || voiceOverEnabled) {
                    searchField
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id("library.searchRow")
                        .moveDisabled(true)
                }
                Section {
                    if hasQuery {
                        ForEach(displayedNotebooks) { notebook in notebookRow(notebook) }
                    } else {
                        ForEach(store.rootItems) { item in
                            rootItemRow(item)
                                .background {
                                    if item.id == store.rootItems.first?.id {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: FirstNotebookPosition.self,
                                                value: geometry.frame(in: .named("notebookList")).minY
                                            )
                                        }
                                    }
                                }
                        }
                            .onMove { reorderItems(from: $0, to: $1, in: nil) }
                            .moveDisabled(isBusy)
                    }
                }
            }
            .environment(\.editMode, .constant(hasQuery ? .inactive : .active))
            .listStyle(.insetGrouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 80, for: .scrollContent)
            .coordinateSpace(name: "notebookList")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                searchPull.updateWidth(width)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { gesture in
                        searchPull.drag(
                            startX: gesture.startLocation.x,
                            horizontal: gesture.translation.width,
                            vertical: gesture.translation.height,
                            isEnabled: !isPad && !showsSearch && !voiceOverEnabled && navigation.path.isEmpty
                        )
                    }
                    .onEnded { _ in
                        let shouldOpen = searchPull.release()
                        if shouldOpen {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                showsSearch = true
                            }
                        }
                    }
            )
            .onPreferenceChange(FirstNotebookPosition.self) { position in
                searchPull.updatePosition(
                    position,
                    isEnabled: !isPad && !showsSearch && !voiceOverEnabled && navigation.path.isEmpty
                )
            }
            .onChange(of: showsSearch) { _, visible in
                if visible { scroll.scrollTo("library.searchRow", anchor: .top) }
            }
            .overlay {
                if hasQuery && displayedNotebooks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func closeSearch() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showsSearch = false
            searchText = ""
        }
        searchPull.reset(includingBaseline: true)
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        Button {
            openNotebook(notebook.id)
        } label: {
            NotebookRow(notebook: notebook, error: store.notebookErrors[notebook.id], folderName: hasQuery ? store.folderName(for: notebook) : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.notebook.\(notebook.id.uuidString)")
        .accessibilityHint("Open notebook")
        .contextMenu {
            NotebookMenuActions(store: store, notebook: notebook, presentation: presentation)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                presentation.notebookToAddPages = notebook.id
            } label: {
                Label("Add Pages", systemImage: "doc.badge.plus")
            }
            .tint(.accentColor)
            .disabled(store.notebookErrors[notebook.id] != nil)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                presentation.archive(notebook.id, store: store)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .accessibilityActions {
            let folderID = store.effectiveFolderID(for: notebook)
            let ids = itemIDs(in: folderID)
            if !hasQuery, let index = ids.firstIndex(of: notebook.id) {
                if index > 0 {
                    Button("Move Earlier") { moveItem(notebook.id, by: -1, in: folderID) }
                }
                if index < ids.count - 1 {
                    Button("Move Later") { moveItem(notebook.id, by: 1, in: folderID) }
                }
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func rootItemRow(_ item: LibraryItem) -> some View {
        switch item {
        case let .notebook(notebook):
            notebookRow(notebook)
        case let .folder(folder):
            folderRow(folder)
        }
    }

    private func folderRow(_ folder: NotebookFolder) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { folderExpansion.isExpanded(folder.id) },
            set: { folderExpansion.setExpanded($0, for: folder.id) }
        )) {
            if store.notebooks(in: folder.id).isEmpty {
                Text("No Notebooks")
                    .foregroundStyle(.secondary)
                    .moveDisabled(true)
            } else {
                ForEach(store.notebooks(in: folder.id)) { notebook in
                    notebookRow(notebook)
                }
                .onMove { reorderItems(from: $0, to: $1, in: folder.id) }
                .moveDisabled(isBusy)
            }
        } label: {
            Label(folder.name, systemImage: "folder")
                .font(.headline)
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Rename Folder", systemImage: "pencil") {
                        folderToRename = folder.id
                        folderName = folder.name
                        showsFolderName = true
                    }
                    .disabled(isBusy)
                    Button("Delete Folder", systemImage: "trash", role: .destructive) {
                        folderToDelete = folder
                    }
                    .disabled(isBusy)
                }
                .accessibilityIdentifier("library.folder.\(folder.id.uuidString)")
                .accessibilityActions {
                    if let index = store.rootItems.firstIndex(where: { $0.id == folder.id }) {
                        if index > 0 {
                            Button("Move Earlier") { moveItem(folder.id, by: -1, in: nil) }
                        }
                        if index < store.rootItems.count - 1 {
                            Button("Move Later") { moveItem(folder.id, by: 1, in: nil) }
                        }
                    }
                }
        }
    }

    private func itemIDs(in folderID: UUID?) -> [UUID] {
        if let folderID { return store.notebooks(in: folderID).map(\.id) }
        return store.rootItems.map(\.id)
    }

    private func reorderItems(from source: IndexSet, to destination: Int, in folderID: UUID?) {
        guard !hasQuery, !isBusy else { return }
        var ids = itemIDs(in: folderID)
        ids.move(fromOffsets: source, toOffset: destination)
        saveOrder(ids, in: folderID)
    }

    private func moveItem(_ id: UUID, by offset: Int, in folderID: UUID?) {
        guard !hasQuery, !isBusy else { return }
        var ids = itemIDs(in: folderID)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        saveOrder(ids, in: folderID)
    }

    private func saveOrder(_ ids: [UUID], in folderID: UUID?) {
        guard !isBusy else { return }
        isSavingOrder = true
        Task {
            defer { isSavingOrder = false }
            do { try await store.reorderItems(inFolderID: folderID, orderedIDs: ids) }
            catch { presentation.errorMessage = error.localizedDescription }
        }
    }

    private var createNotebookMenu: some View {
        Menu {
            Section("Create New Notebook") {
                AcquisitionMenuChoices { source in
                    presentation.show(.acquisition(nil, source))
                }
            }
            Button("Create Folder", systemImage: "folder.badge.plus") {
                folderToRename = nil
                folderName = ""
                showsFolderName = true
            }
            .accessibilityIdentifier("library.createFolder")
        } label: {
            Label("Create New Notebook", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Create notebook or folder")
        .accessibilityIdentifier("library.create")
    }

    private func saveFolderName() {
        guard !isBusy else { return }
        let name = folderName
        let folderID = folderToRename
        Task {
            do {
                if let folderID {
                    try await store.renameFolder(folderID, name: name)
                } else {
                    let id = try await store.createFolder(name: name)
                    folderExpansion.setExpanded(true, for: id)
                }
            } catch {
                presentation.errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteFolder() {
        guard !isBusy, let folder = folderToDelete else { return }
        folderToDelete = nil
        Task {
            do { try await store.deleteFolder(folder.id) }
            catch { presentation.errorMessage = error.localizedDescription }
        }
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
        .disabled(isBusy)
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
    let folderName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NotebookIcon(notebook: notebook)
            VStack(alignment: .leading, spacing: 4) {
                Text(notebook.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(notebook.pageCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let folderName {
                    Label(folderName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

private struct FirstNotebookPosition: PreferenceKey {
    static var defaultValue: CGFloat? { nil }

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct SearchPullIndicator: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
        }
        .frame(width: 40, height: 40)
        .padding(2)
        .accessibilityHidden(true)
    }
}

private struct LibraryCircleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .font(.system(size: 20))
                .tint(.primary)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .font(.system(size: 20))
                .tint(.primary)
                .buttonStyle(.plain)
                .padding(8)
                .background(.regularMaterial, in: Circle())
        }
    }
}

@MainActor
@Observable
final class LibraryNavigation {
    var path: [UUID] = []
    private(set) var requestedPageID: UUID?
    private(set) var selectionRequestID = UUID()
    private(set) var readerSession = ReaderSession()

    func open(_ notebookID: UUID, pageID: UUID? = nil) {
        requestedPageID = pageID
        selectionRequestID = UUID()
        if path != [notebookID] {
            readerSession = ReaderSession()
            path = [notebookID]
        }
    }
}
