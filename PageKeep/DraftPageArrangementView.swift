import SwiftUI

struct DraftPageArrangementView: View {
    let store: LibraryStore
    let notebookID: UUID?
    let draft: NotebookDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showsDeleteConfirmation = false
    @State private var showsMoveDestination = false
    @State private var errorMessage: String?

    private var pageIDs: [UUID] { draft.pages.map(\.id) }
    private var isBusy: Bool { draft.isSaving || store.isBusy }
    private var notebook: Notebook? { draft.baseNotebook }
    private var savedURL: URL? { draft.pinnedPDFURL }

    var body: some View {
        NavigationStack {
            Group {
                if draft.pages.isEmpty {
                    ContentUnavailableView("No Pages", systemImage: "doc", description: Text("Use Add Pages in the notebook form to add scans or a PDF."))
                } else {
                    pageList
                }
            }
            .navigationTitle("Arrange Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !draft.pages.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            isSelecting.toggle()
                            selectedIDs.removeAll()
                        }
                        .accessibilityLabel(isSelecting ? "Cancel page selection" : "Select pages")
                        .accessibilityIdentifier("arranger.select")
                        .disabled(isBusy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("arranger.done")
                        .disabled(isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting, !draft.pages.isEmpty { selectionActions }
            }
        }
        .sheet(isPresented: $showsMoveDestination) {
            DraftPageMoveDestinationView(pages: draft.pages, selectedIDs: selectedIDs) { destination in
                try draft.movePages(ids: selectedIDs, before: destination)
            }
        }
        .onChange(of: pageIDs) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "page" : "pages") from this draft?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Pages", role: .destructive, action: deleteSelectedPages)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("These changes are saved only when you save the notebook.")
        }
        .alert("Couldn’t Arrange Pages", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var pageList: some View {
        let sources = DraftPagePreviewSources(notebook: notebook, savedURL: savedURL, additions: draft.additions)
        return List {
            Section {
                ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                    Group {
                        if isSelecting {
                            Button {
                                toggleSelection(page.id)
                            } label: {
                                pageRow(page, index: index, source: sources.source(for: page))
                            }
                            .buttonStyle(.plain)
                        } else {
                            pageRow(page, index: index, source: sources.source(for: page))
                        }
                    }
                    .disabled(isBusy)
                    .moveDisabled(isSelecting || isBusy)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page \(index + 1)")
                    .accessibilityValue(isSelecting ? (selectedIDs.contains(page.id) ? "Selected" : "Not selected") : pageStatus(page))
                    .accessibilityAddTraits(selectedIDs.contains(page.id) ? .isSelected : [])
                    .accessibilityIdentifier("arranger.page.\(page.id.uuidString)")
                    .accessibilityActions {
                        if !isSelecting, !isBusy {
                            if index > 0 {
                                Button("Move Earlier") { movePage(page.id, by: -1) }
                            }
                            if index < draft.pages.count - 1 {
                                Button("Move Later") { movePage(page.id, by: 1) }
                            }
                        }
                    }
                }
                .onMove(perform: reorderPages)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSelecting ? "Tap pages to select them." : "Drag the handles to reorder pages, or use Select to move or delete multiple pages.")
                    Text("Changes stay in this draft until you tap Save in the notebook form.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelecting ? .inactive : .active))
    }

    private func pageRow(_ page: DraftPage, index: Int, source: DraftPagePreviewSource?) -> some View {
        HStack(spacing: 16) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(page.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selectedIDs.contains(page.id) ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            if let source {
                PageThumbnail(url: source.url, pageIndex: source.pageIndex)
                    .frame(width: 84, height: 112)
            } else {
                Image(systemName: "doc.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 84, height: 112)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Page \(index + 1)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(pageStatus(page))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func pageStatus(_ page: DraftPage) -> String {
        switch page.source {
        case .existing: "Saved page"
        case .prepared: "Pending page"
        }
    }

    private var selectionActions: some View {
        VStack(spacing: 6) {
            Text("\(selectedIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    selectAllButton
                    moveSelectionButton
                    deleteSelectionButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    selectAllButton
                    Spacer()
                    moveSelectionButton
                    Spacer()
                    deleteSelectionButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
        .disabled(isBusy)
    }

    private var selectAllButton: some View {
        Button(selectedIDs.count == pageIDs.count ? "Deselect All" : "Select All") {
            selectedIDs = selectedIDs.count == pageIDs.count ? [] : Set(pageIDs)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("arranger.selectAll")
    }

    private var moveSelectionButton: some View {
        Button("Move \(selectedIDs.count)", systemImage: "arrow.up.arrow.down") {
            showsMoveDestination = true
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Move \(selectedIDs.count) selected \(selectedIDs.count == 1 ? "page" : "pages")")
        .accessibilityIdentifier("arranger.move")
        .disabled(selectedIDs.isEmpty)
    }

    private var deleteSelectionButton: some View {
        Button("Delete \(selectedIDs.count)", systemImage: "trash", role: .destructive) {
            showsDeleteConfirmation = true
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Delete \(selectedIDs.count) selected \(selectedIDs.count == 1 ? "page" : "pages")")
        .accessibilityIdentifier("arranger.delete")
        .disabled(selectedIDs.isEmpty)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func reorderPages(from offsets: IndexSet, to destination: Int) {
        guard !isSelecting, !isBusy else { return }
        var ids = pageIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        saveOrder(ids)
    }

    private func movePage(_ id: UUID, by offset: Int) {
        guard !isSelecting, !isBusy, let index = pageIDs.firstIndex(of: id), pageIDs.indices.contains(index + offset) else { return }
        var ids = pageIDs
        ids.swapAt(index, index + offset)
        saveOrder(ids)
    }

    private func saveOrder(_ ids: [UUID]) {
        do { try draft.reorderPages(orderedIDs: ids) }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteSelectedPages() {
        do {
            try draft.removePages(ids: selectedIDs)
            selectedIDs.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DraftPageMoveDestinationView: View {
    let pages: [DraftPage]
    let selectedIDs: Set<UUID>
    let onMove: (UUID?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var availablePages: [(index: Int, page: DraftPage)] {
        pages.enumerated().compactMap { index, page in
            selectedIDs.contains(page.id) ? nil : (index, page)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Beginning") { move(before: availablePages.first?.page.id) }
                        .accessibilityIdentifier("arranger.destination.beginning")
                    Button("End") { move(before: nil) }
                        .accessibilityIdentifier("arranger.destination.end")
                }
                if !availablePages.isEmpty {
                    Section("Move Before") {
                        ForEach(availablePages, id: \.page.id) { item in
                            Button("Before Page \(item.index + 1)") { move(before: item.page.id) }
                                .accessibilityIdentifier("arranger.destination.before.\(item.page.id.uuidString)")
                        }
                    }
                }
            }
            .navigationTitle("Move \(selectedIDs.count) \(selectedIDs.count == 1 ? "Page" : "Pages")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("arranger.destination.cancel")
                }
            }
            .alert("Couldn’t Move Pages", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func move(before destination: UUID?) {
        do {
            try onMove(destination)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
