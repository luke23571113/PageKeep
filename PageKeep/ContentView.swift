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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { store.isBusy || isSavingOrder }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            Group {
                if store.isLoading {
                    ProgressView("Loading notebooks…")
                } else if let error = store.loadError {
                    storageError(error)
                } else if store.activeNotebooks.isEmpty {
                    emptyLibrary
                } else {
                    notebookList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Notebooks")
            .overlay(alignment: .bottomLeading) {
                settingsButton.padding(16)
            }
            .navigationDestination(for: UUID.self) { id in
                NotebookView(
                    store: store,
                    notebookID: id,
                    initialPageID: navigation.requestedPageID,
                    selectionRequestID: navigation.selectionRequestID,
                    presentation: presentation
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if navigation.path.isEmpty {
                createNotebookMenu
                    .modifier(LibraryCircleButton())
                    .disabled(isBusy || store.loadError != nil)
                    .padding(.trailing, 24)
                    .padding(.top, 10)
            }
        }
        .overlay(alignment: .top) {
            if navigation.path.isEmpty && searchPull.isPulling && searchPull.distance > 8 {
                SearchPullIndicator(progress: min(searchPull.distance / 72, 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .offset(y: 10)
                    .allowsHitTesting(false)
            }
        }
        .notebookPresentations(store: store, presentation: presentation) { id, pageID in
            navigation.open(id, pageID: pageID)
        }
        .task { await store.load() }
        .onChange(of: navigation.path) { _, _ in
            presentation.cancelPreparation()
            searchPull.reset(includingBaseline: true)
        }
        .onChange(of: store.activeNotebooks.first?.id) { _, _ in
            searchPull.reset(includingBaseline: true)
        }
        .onDisappear {
            searchPull.reset()
            presentation.cancelPreparation()
        }
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
                if showsSearch || voiceOverEnabled {
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
                        ForEach(store.activeNotebooks) { notebook in
                            notebookRow(notebook)
                                .background {
                                    if notebook.id == store.activeNotebooks.first?.id {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: FirstNotebookPosition.self,
                                                value: geometry.frame(in: .named("notebookList")).minY
                                            )
                                        }
                                    }
                                }
                        }
                            .onMove(perform: reorderNotebooks)
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
                            isEnabled: !showsSearch && !voiceOverEnabled && navigation.path.isEmpty
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
                    isEnabled: !showsSearch && !voiceOverEnabled && navigation.path.isEmpty
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
            navigation.open(notebook.id)
        } label: {
            NotebookRow(notebook: notebook, error: store.notebookErrors[notebook.id])
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
            if !hasQuery, let index = store.activeNotebooks.firstIndex(where: { $0.id == notebook.id }) {
                if index > 0 {
                    Button("Move Earlier") { moveNotebook(notebook.id, by: -1) }
                }
                if index < store.activeNotebooks.count - 1 {
                    Button("Move Later") { moveNotebook(notebook.id, by: 1) }
                }
            }
        }
        .disabled(isBusy)
    }

    private func reorderNotebooks(from source: IndexSet, to destination: Int) {
        guard !hasQuery, !isBusy else { return }
        var ids = store.activeNotebooks.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        saveOrder(ids)
    }

    private func moveNotebook(_ id: UUID, by offset: Int) {
        guard !hasQuery, !isBusy else { return }
        var ids = store.activeNotebooks.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        saveOrder(ids)
    }

    private func saveOrder(_ ids: [UUID]) {
        guard !isBusy else { return }
        isSavingOrder = true
        Task {
            defer { isSavingOrder = false }
            do { try await store.reorderNotebooks(orderedActiveIDs: ids) }
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
        } label: {
            Label("Create New Notebook", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
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

    func open(_ notebookID: UUID, pageID: UUID? = nil) {
        requestedPageID = pageID
        selectionRequestID = UUID()
        if path != [notebookID] {
            path = [notebookID]
        }
    }
}
