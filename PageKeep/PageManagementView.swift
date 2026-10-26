import SwiftUI

struct PageManagementView: View {
    let store: LibraryStore
    let notebookID: UUID
    let onOpenPage: (UUID) -> Void
    @State private var isSelecting = false
    @State private var isPerformingAction = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var isBusy: Bool { store.isBusy || isPerformingAction }
    private var notebook: Notebook? { store.notebook(id: notebookID) }
    private var pageIDs: [UUID] { notebook?.pages.map(\.id) ?? [] }

    var body: some View {
        Group {
            if let notebook, !notebook.pages.isEmpty {
                pageList(notebook)
            } else {
                ContentUnavailableView("No Pages", systemImage: "doc", description: Text("Add scans or a PDF from the notebook."))
            }
        }
        .navigationTitle("Manage Pages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !pageIDs.isEmpty {
                    Button(isSelecting ? "Cancel" : "Select") {
                        withAnimation {
                            isSelecting.toggle()
                            selectedIDs.removeAll()
                        }
                    }
                    .accessibilityIdentifier("manager.select")
                    .accessibilityLabel(isSelecting ? "Cancel page selection" : "Select pages")
                    .disabled(isBusy)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, !pageIDs.isEmpty { selectionActions }
        }
        .interactiveDismissDisabled(isBusy)
        .onChange(of: pageIDs) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .confirmationDialog("Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "page" : "pages")?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Pages", role: .destructive) {
                let ids = selectedIDs
                perform {
                    try await store.deletePages(in: notebookID, ids: ids)
                    selectedIDs.subtract(ids)
                }
            }
        } message: {
            Text("These pages will be permanently removed from the notebook.")
        }
        .alert("Couldn’t Update Pages", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func pageList(_ notebook: Notebook) -> some View {
        List {
            Section {
                ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        if isSelecting {
                            if selectedIDs.contains(page.id) {
                                selectedIDs.remove(page.id)
                            } else {
                                selectedIDs.insert(page.id)
                            }
                        } else {
                            onOpenPage(page.id)
                        }
                    } label: {
                        pageRow(notebook, pageID: page.id, index: index)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .moveDisabled(isSelecting || isBusy)
                    .accessibilityIdentifier("manager.page.\(page.id.uuidString)")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Page \(index + 1)")
                    .accessibilityValue(isSelecting ? (selectedIDs.contains(page.id) ? "Selected" : "Not selected") : "")
                    .accessibilityActions {
                        if !isSelecting, !isBusy {
                            if index > 0 {
                                Button("Move Earlier") { movePage(page.id, by: -1) }
                            }
                            if index < notebook.pages.count - 1 {
                                Button("Move Later") { movePage(page.id, by: 1) }
                            }
                        }
                    }
                }
                .onMove(perform: movePages)
            } footer: {
                Text(isSelecting ? "\(notebook.pageCountLabel) · Tap pages to select them." : "Tap a page to open it. Drag the handles to reorder.")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelecting ? .inactive : .active))
    }

    private func pageRow(_ notebook: Notebook, pageID: UUID, index: Int) -> some View {
        HStack(spacing: 16) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(pageID) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selectedIDs.contains(pageID) ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            if let url = store.pdfURL(for: notebook) {
                PageThumbnail(url: url, pageIndex: index)
                    .frame(width: 72, height: 96)
                    .accessibilityHidden(true)
            }
            Text("Page \(index + 1)")
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var selectionActions: some View {
        VStack(spacing: 4) {
            Text("\(selectedIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(selectedIDs.count == pageIDs.count ? "Deselect All" : "Select All") {
                    selectedIDs = selectedIDs.count == pageIDs.count ? [] : Set(pageIDs)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("manager.selectAll")
                Spacer()
                Button("Rotate", systemImage: "rotate.right") { rotateSelectedPages() }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Rotate selected pages clockwise")
                    .accessibilityIdentifier("manager.rotate")
                    .disabled(selectedIDs.isEmpty)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    showsDeleteConfirmation = true
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Delete selected pages")
                .accessibilityIdentifier("manager.delete")
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(.bar)
        .disabled(isBusy)
    }

    private func rotateSelectedPages() {
        let ids = selectedIDs
        perform { try await store.rotatePages(in: notebookID, ids: ids) }
    }

    private func movePages(from offsets: IndexSet, to destination: Int) {
        guard !isSelecting, !isBusy else { return }
        var ids = pageIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        saveOrder(ids)
    }

    private func movePage(_ id: UUID, by offset: Int) {
        guard !isSelecting, !isBusy, let index = pageIDs.firstIndex(of: id) else { return }
        let target = index + offset
        guard pageIDs.indices.contains(target) else { return }
        var ids = pageIDs
        ids.swapAt(index, target)
        saveOrder(ids)
    }

    private func saveOrder(_ ids: [UUID]) {
        perform { try await store.reorderPages(in: notebookID, orderedIDs: ids) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }

}
