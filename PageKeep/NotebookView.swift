import SwiftUI

struct NotebookView: View {
    let store: LibraryStore
    let notebookID: UUID
    let presentation: NotebookPresentation
    let initialPageID: UUID?
    let selectionRequestID: UUID
    @State private var currentPageID: UUID?
    @State private var knownPageIDs: [UUID] = []
    @State private var isPanelOpen = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: LibraryStore,
        notebookID: UUID,
        initialPageID: UUID? = nil,
        selectionRequestID: UUID,
        presentation: NotebookPresentation
    ) {
        self.store = store
        self.notebookID = notebookID
        self.initialPageID = initialPageID
        self.selectionRequestID = selectionRequestID
        self.presentation = presentation
        _currentPageID = State(initialValue: initialPageID)
    }

    var body: some View {
        Group {
            if let notebook = store.notebook(id: notebookID) {
                notebookContent(notebook)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        ReaderActionPanel(
                            notebook: notebook,
                            expanded: isPanelOpen || voiceOverEnabled,
                            isBusy: store.isBusy,
                            pagesUnavailable: store.notebookErrors[notebookID] != nil,
                            showsPageNumber: settings.showsPageNumber,
                            pageNumber: pageNumber(in: notebook),
                            onAddPages: addPages,
                            onManage: { presentation.show(.manage(notebookID)) },
                            onShare: { presentation.share(notebook, store: store) },
                            onExpand: { setPanelOpen(true) },
                            onClose: closePanel
                        )
                    }
                    .onChange(of: notebook.pages.map(\.id), initial: true) { _, ids in
                        followCurrentPage(in: ids)
                    }
            } else {
                ContentUnavailableView("Notebook Unavailable", systemImage: "book.closed")
            }
        }
        .navigationTitle(store.notebook(id: notebookID)?.name ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let notebook = store.notebook(id: notebookID) {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                        .accessibilityIdentifier("viewer.back")
                        .tint(.primary)
                }
                ToolbarItem(placement: .principal) {
                    ReaderTitle(name: notebook.name)
                        .onTapGesture { closePanel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ReaderNotebookMenu(
                        store: store,
                        notebook: notebook,
                        presentation: presentation,
                        isBusy: store.isBusy,
                        pagesUnavailable: store.notebookErrors[notebookID] != nil
                    ) {
                        closePanel()
                    }
                    .equatable()
                }
            }
        }
        .onChange(of: selectionRequestID) { _, _ in
            if let initialPageID { currentPageID = initialPageID }
        }
        .onChange(of: store.notebook(id: notebookID)?.isArchived, initial: true) { _, archived in
            if archived == true || store.notebook(id: notebookID) == nil { dismiss() }
        }
    }

    @ViewBuilder
    private func notebookContent(_ notebook: Notebook) -> some View {
        if let error = store.notebookErrors[notebookID] {
            ContentUnavailableView {
                Label("Pages Unavailable", systemImage: "exclamationmark.triangle")
            } description: { Text(error) }
        } else if notebook.pages.isEmpty {
            ContentUnavailableView {
                Label("No Pages Yet", systemImage: "doc")
            } description: {
                Text("Add scans or a PDF to this notebook.")
            } actions: {
                Menu("Add Pages", systemImage: "doc.badge.plus") {
                    AcquisitionMenuChoices(onChoose: addPages)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
            }
        } else if let url = store.pdfURL(for: notebook) {
            PDFReader(
                url: url,
                pageIDs: notebook.pages.map(\.id),
                currentPageID: $currentPageID,
                readingMode: settings.readingMode,
                onInteraction: { closePanel() }
            )
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            ContentUnavailableView("Pages Unavailable", systemImage: "exclamationmark.triangle", description: Text("The saved PDF could not be found."))
        }
    }

    private func closePanel() {
        if isPanelOpen, !voiceOverEnabled { setPanelOpen(false) }
    }

    private func setPanelOpen(_ isOpen: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            self.isPanelOpen = isOpen
        }
    }

    private func addPages(from source: AcquisitionSource) {
        presentation.show(.acquisition(notebookID, source))
    }

    private func pageNumber(in notebook: Notebook) -> Int {
        (notebook.pages.firstIndex { $0.id == currentPageID } ?? 0) + 1
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

private struct ReaderTitle: View {
    let name: String

    @ViewBuilder
    var body: some View {
        let title = Text(name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        if #available(iOS 26.0, *) {
            title.glassEffect(.regular, in: Capsule())
        } else {
            title.background(.regularMaterial, in: Capsule())
        }
    }

}

private struct ReaderActionPanel: View {
    let notebook: Notebook
    let expanded: Bool
    let isBusy: Bool
    let pagesUnavailable: Bool
    let showsPageNumber: Bool
    let pageNumber: Int
    let onAddPages: (AcquisitionSource) -> Void
    let onManage: () -> Void
    let onShare: () -> Void
    let onExpand: () -> Void
    let onClose: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        return GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 8) {
                readerActions(notebook, expanded: expanded)
                    .frame(width: expanded ? (geometry.size.width - 32) * 0.8 : nil)
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .accessibilityLabel("Saving changes")
                }
                if showsPageNumber, !notebook.pages.isEmpty {
                    Text("\(pageNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityLabel("Page \(pageNumber) of \(notebook.pageCount)")
                        .accessibilityIdentifier("viewer.pageNumber")
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(16)
            .background {
                Color.clear.contentShape(Rectangle()).onTapGesture { onClose() }
            }
        }
        .frame(height: 88)
    }

    @ViewBuilder
    private func readerActions(_ notebook: Notebook, expanded: Bool) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                readerButtons(notebook, expanded: expanded)
            }
        } else {
            readerButtons(notebook, expanded: expanded)
        }
    }

    private func readerButtons(_ notebook: Notebook, expanded: Bool) -> some View {
        HStack(spacing: expanded ? 0 : 16) {
            if expanded {
                Menu {
                    AcquisitionMenuChoices(onChoose: onAddPages)
                } label: {
                    readerIcon("Add Pages", systemImage: "doc.badge.plus", expanded: true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("viewer.add")
                .disabled(isBusy || pagesUnavailable)
                Button {
                    onManage()
                } label: {
                    readerIcon("Manage Pages", systemImage: "square.grid.2x2", expanded: true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("viewer.manage")
                .disabled(isBusy || pagesUnavailable)
                Button {
                    onShare()
                } label: {
                    readerIcon("Share", systemImage: "square.and.arrow.up", expanded: true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("viewer.share")
                .disabled(isBusy || notebook.pages.isEmpty || pagesUnavailable)
            } else {
                Button {
                    onExpand()
                } label: {
                    readerIcon("Show Reader Actions", systemImage: "chevron.right")
                }
                .accessibilityIdentifier("viewer.panel")
                .accessibilityValue("Collapsed")
            }
        }
        .modifier(ReaderIconButtons())
        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard !voiceOverEnabled,
                  abs(value.translation.width) > abs(value.translation.height) else { return }
            if value.translation.width > 0 { onExpand() } else { onClose() }
        })
    }

    private func readerIcon(_ title: String, systemImage: String, expanded: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: expanded ? 19 : 14, weight: .medium))
            .frame(width: expanded ? 44 : 28, height: expanded ? 44 : 28)
    }

}

private struct ReaderIconButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
        } else {
            content
                .buttonStyle(ReaderMaterialButton())
                .tint(.primary)
        }
    }
}

private struct ReaderMaterialButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// Panel changes should not rebuild a menu while UIKit is opening it.
private struct ReaderNotebookMenu: View, Equatable {
    let store: LibraryStore
    let notebook: Notebook
    let presentation: NotebookPresentation
    let isBusy: Bool
    let pagesUnavailable: Bool
    let onOpen: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.presentation === rhs.presentation
            && lhs.notebook == rhs.notebook && lhs.isBusy == rhs.isBusy
            && lhs.pagesUnavailable == rhs.pagesUnavailable
    }

    var body: some View {
        Menu {
            NotebookMenuActions(store: store, notebook: notebook, presentation: presentation)
        } label: {
            Label("Notebook Actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onOpen() })
        .accessibilityIdentifier("viewer.actions")
        .disabled(isBusy)
        .tint(.primary)
    }
}
