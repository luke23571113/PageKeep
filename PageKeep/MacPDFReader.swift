import PDFKit
import SwiftUI

struct MacPDFReader: NSViewRepresentable {
    let url: URL
    let notebook: Notebook
    let requestedPageID: UUID?
    let readingMode: ReadingMode
    let positions: ReadingPositionStore
    let onPageChange: (Int) -> Void
    var session: ReaderSession? = nil
    var selectionRequestID: UUID? = nil

    private var pageIDs: [UUID] { notebook.pages.map(\.id) }
    private var currentPageID: UUID? {
        positions.pageID(for: notebook.id, in: pageIDs)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MacPDFReaderView {
        let view = MacPDFReaderView()
        context.coordinator.view = view
        view.onViewportWillChange = { [weak coordinator = context.coordinator] in coordinator?.beginResize() }
        view.onViewportDidChange = { [weak coordinator = context.coordinator] in coordinator?.endResize() }
        view.retryButton.target = context.coordinator
        view.retryButton.action = #selector(Coordinator.retry)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view.pdfView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scaleChanged), name: .PDFViewScaleChanged, object: view.pdfView)
        context.coordinator.update(self)
        return view
    }

    func updateNSView(_ view: MacPDFReaderView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: MacPDFReaderView, coordinator: Coordinator) {
        coordinator.stop()
        view.retryButton.target = nil
        view.onViewportWillChange = nil
        view.onViewportDidChange = nil
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacPDFReader
        weak var view: MacPDFReaderView?
        var loadedURL: URL?
        var loading: Task<Void, Never>?
        private var generation = UUID()
        private var installedPageIDs: [UUID] = []
        private weak var installedDocument: PDFDocument?
        private var isUpdating = false
        private var appliedReadingMode: ReadingMode?
        private var layoutGeneration = UUID()
        private var appliedSelectionRequestID: UUID?
        private var resizePage: PDFPage?
        private var resizeZoom: CGFloat = 1

        init(parent: MacPDFReader) {
            self.parent = parent
        }

        func stop() {
            loading?.cancel()
            loading = nil
            installedDocument = nil
            installedPageIDs = []
            generation = UUID()
            layoutGeneration = UUID()
            view = nil
        }

        func update(_ parent: MacPDFReader) {
            self.parent = parent
            applyReadingMode()
            guard loadedURL == parent.url else {
                load()
                return
            }
            guard loading == nil, appliedSelectionRequestID != parent.selectionRequestID else { return }
            appliedSelectionRequestID = parent.selectionRequestID
            layoutGeneration = UUID()
            guard let view, let document = view.pdfView.document,
                  let id = parent.requestedPageID,
                  let index = parent.pageIDs.firstIndex(of: id),
                  index < document.pageCount,
                  let page = document.page(at: index), view.pdfView.currentPage !== page else { return }
            isUpdating = true
            view.pdfView.go(to: page)
            isUpdating = false
            pageChanged()
        }

        @objc func scaleChanged() {
            guard !isUpdating else { return }
            if let pdfView = view?.pdfView, pdfView.document != nil {
                let fitScale = pdfView.scaleFactorForSizeToFit
                if fitScale > 0 { parent.session?.relativeZoom = pdfView.scaleFactor / fitScale }
            }
        }

        func beginResize() {
            guard loading == nil, let pdfView = view?.pdfView, pdfView.document != nil,
                  let page = pdfView.currentPage else { return }
            resizePage = page
            let fitScale = pdfView.scaleFactorForSizeToFit
            resizeZoom = parent.session?.relativeZoom ?? (fitScale > 0 ? pdfView.scaleFactor / fitScale : 1)
            isUpdating = true
        }

        func endResize() {
            guard let page = resizePage else { return }
            resizePage = nil
            restoreZoom(resizeZoom, on: page)
        }

        private func applyReadingMode() {
            guard let view, appliedReadingMode != parent.readingMode else { return }
            let pdfView = view.pdfView
            let page = pdfView.currentPage
            let fitScale = pdfView.scaleFactorForSizeToFit
            let relativeZoom = fitScale > 0 ? pdfView.scaleFactor / fitScale : 1
            appliedReadingMode = parent.readingMode
            isUpdating = true
            pdfView.backgroundColor = .windowBackgroundColor
            if parent.readingMode == .horizontal {
                pdfView.displayMode = .singlePage
                pdfView.displayDirection = .horizontal
            } else {
                pdfView.displayMode = .singlePageContinuous
                pdfView.displayDirection = .vertical
            }
            pdfView.layoutDocumentView()
            if let page { pdfView.go(to: page) }
            isUpdating = false
            guard page != nil else { return }
            restoreZoom(relativeZoom, on: page)
        }

        private func restoreZoom(_ relativeZoom: CGFloat, on page: PDFPage?) {
            let layoutToken = UUID()
            layoutGeneration = layoutToken
            let document = view?.pdfView.document
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == layoutToken,
                      let pdfView = self.view?.pdfView, pdfView.document === document else { return }
                self.isUpdating = true
                pdfView.layoutSubtreeIfNeeded()
                if let page { pdfView.go(to: page) }
                let fitScale = pdfView.scaleFactorForSizeToFit
                if abs(relativeZoom - 1) < 0.01 {
                    // Fitted pages should keep adapting when the viewport changes.
                    pdfView.autoScales = true
                } else if fitScale > 0 {
                    let requestedScale = fitScale * relativeZoom
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(max(requestedScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
                }
                self.isUpdating = false
                self.parent.session?.relativeZoom = relativeZoom
            }
        }

        @objc func retry() {
            load()
        }

        private func load() {
            guard let view else { return }
            loading?.cancel()
            loadedURL = parent.url
            let url = parent.url
            let token = UUID()
            generation = token
            let oldIndex = view.pdfView.currentPage.flatMap { view.pdfView.document?.index(for: $0) } ?? 0
            let fitScale = view.pdfView.scaleFactorForSizeToFit
            let hasDocument = view.pdfView.document != nil
            let relativeZoom = hasDocument && fitScale > 0
                ? view.pdfView.scaleFactor / fitScale : parent.session?.relativeZoom ?? 1
            view.setLoading()
            loading = Task { @MainActor [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) {
                    MacLoadedPDF(document: PDFDocument(url: url))
                }.value
                guard !Task.isCancelled, let self, self.generation == token, let view = self.view else { return }
                self.loading = nil
                guard let document = loaded.document, !document.isLocked, document.pageCount > 0,
                      document.pageCount == self.parent.pageIDs.count else {
                    view.setError("This notebook could not be opened. Please try again.")
                    return
                }
                self.isUpdating = true
                self.installedDocument = document
                self.installedPageIDs = self.parent.pageIDs
                view.pdfView.document = document
                let requested = self.parent.positions.pageID(
                    for: self.parent.notebook.id, in: self.parent.pageIDs,
                    requestedPageID: self.appliedSelectionRequestID != self.parent.selectionRequestID ? self.parent.requestedPageID : nil
                )
                let requestedIndex = requested.flatMap { self.parent.pageIDs.firstIndex(of: $0) }
                self.appliedSelectionRequestID = self.parent.selectionRequestID
                let index = min(requestedIndex ?? oldIndex, document.pageCount - 1)
                if let page = document.page(at: max(0, index)) {
                    view.pdfView.go(to: page)
                }
                self.isUpdating = false
                self.restoreZoom(relativeZoom, on: view.pdfView.currentPage)
                view.setReady()
                self.pageChanged()
            }
        }

        @objc func pageChanged() {
            guard !isUpdating, loading == nil, let view,
                  let document = view.pdfView.document,
                  document === installedDocument,
                  installedPageIDs == parent.pageIDs,
                  let page = view.pdfView.currentPage else { return }
            let index = document.index(for: page)
            guard installedPageIDs.indices.contains(index) else { return }
            let id = installedPageIDs[index]
            let token = generation
            let previousSelection = parent.currentPageID
            // PDFKit can notify while SwiftUI is updating this view.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.loading == nil,
                      self.installedPageIDs == self.parent.pageIDs,
                      self.parent.currentPageID == previousSelection,
                      let pdfView = self.view?.pdfView,
                      let document = pdfView.document, document === self.installedDocument,
                      let currentPage = pdfView.currentPage else { return }
                let currentIndex = document.index(for: currentPage)
                guard self.parent.pageIDs.indices.contains(currentIndex),
                      self.parent.pageIDs[currentIndex] == id else { return }
                self.parent.positions.remember(pageID: id, in: self.parent.pageIDs, for: self.parent.notebook.id)
                self.parent.onPageChange(currentIndex + 1)
            }
        }
    }
}

private struct MacLoadedPDF: @unchecked Sendable {
    let document: PDFDocument?
}

final class MacPDFReaderView: NSView {
    let pdfView = PDFView()
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorStack = NSStackView()
    var onViewportWillChange: (() -> Void)?
    var onViewportDidChange: (() -> Void)?
    private var previousSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .windowBackgroundColor
        progress.style = .spinning
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorStack.orientation = .vertical
        errorStack.spacing = 12
        errorStack.addArrangedSubview(errorLabel)
        errorStack.addArrangedSubview(retryButton)
        for child in [pdfView, progress, errorStack] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        errorStack.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        let isResize = previousSize != .zero && previousSize != bounds.size
        previousSize = bounds.size
        if isResize { onViewportWillChange?() }
        super.layout()
        if isResize { onViewportDidChange?() }
    }

    func setLoading() {
        pdfView.isHidden = true
        errorStack.isHidden = true
        progress.startAnimation(nil)
    }

    func setReady() {
        progress.stopAnimation(nil)
        errorStack.isHidden = true
        pdfView.isHidden = false
    }

    func setError(_ message: String) {
        progress.stopAnimation(nil)
        pdfView.isHidden = true
        errorLabel.stringValue = message
        errorStack.isHidden = false
    }
}
