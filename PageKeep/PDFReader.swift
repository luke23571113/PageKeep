import PDFKit
import SwiftUI

struct PDFReader: UIViewRepresentable {
    let url: URL
    let pageIDs: [UUID]
    @Binding var currentPageID: UUID?
    let readingMode: ReadingMode
    let onInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PDFReaderView {
        let view = PDFReaderView()
        context.coordinator.view = view
        view.retryButton.addTarget(context.coordinator, action: #selector(Coordinator.retry), for: .touchUpInside)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view.pdfView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scaleChanged), name: .PDFViewScaleChanged, object: view.pdfView)
        context.coordinator.observeInteractions(in: view.pdfView)
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ view: PDFReaderView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: PDFReaderView, coordinator: Coordinator) {
        coordinator.stop()
        view.retryButton.removeTarget(coordinator, action: nil, for: .allEvents)
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFReader
        weak var view: PDFReaderView?
        var loadedURL: URL?
        var loading: Task<Void, Never>?
        private var generation = UUID()
        private var installedPageIDs: [UUID] = []
        private weak var installedDocument: PDFDocument?
        private var isUpdating = false
        private var appliedReadingMode: ReadingMode?
        private var layoutGeneration = UUID()
        private var interactionGestures: [UIGestureRecognizer] = []

        init(parent: PDFReader) {
            self.parent = parent
        }

        func stop() {
            loading?.cancel()
            loading = nil
            installedDocument = nil
            installedPageIDs = []
            generation = UUID()
            layoutGeneration = UUID()
            for gesture in interactionGestures {
                gesture.view?.removeGestureRecognizer(gesture)
                gesture.delegate = nil
            }
            interactionGestures.removeAll()
            view = nil
        }

        func update(_ parent: PDFReader) {
            self.parent = parent
            applyReadingMode()
            guard loadedURL == parent.url else {
                load()
                return
            }
            guard loading == nil, let view, let document = view.pdfView.document,
                  let id = parent.currentPageID,
                  let index = parent.pageIDs.firstIndex(of: id),
                  index < document.pageCount,
                  let page = document.page(at: index), view.pdfView.currentPage !== page else { return }
            isUpdating = true
            view.pdfView.go(to: page)
            isUpdating = false
        }

        func observeInteractions(in pdfView: PDFView) {
            interactionGestures = [
                UITapGestureRecognizer(target: self, action: #selector(interacted)),
                UIPanGestureRecognizer(target: self, action: #selector(interacted)),
                UIPinchGestureRecognizer(target: self, action: #selector(interacted))
            ]
            for gesture in interactionGestures {
                gesture.cancelsTouchesInView = false
                gesture.delegate = self
                pdfView.addGestureRecognizer(gesture)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func interacted(_ gesture: UIGestureRecognizer) {
            if gesture is UITapGestureRecognizer { view?.becomeFirstResponder() }
            parent.onInteraction()
        }

        @objc func scaleChanged() {
            guard !isUpdating else { return }
            reportInteraction()
        }

        private func reportInteraction() {
            // PDFKit notifications can arrive during a SwiftUI update.
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.parent.onInteraction()
            }
        }

        private func applyReadingMode() {
            guard let view, appliedReadingMode != parent.readingMode else { return }
            let pdfView = view.pdfView
            let page = pdfView.currentPage
            let fitScale = pdfView.scaleFactorForSizeToFit
            let relativeZoom = fitScale > 0 ? pdfView.scaleFactor / fitScale : 1
            appliedReadingMode = parent.readingMode
            isUpdating = true
            pdfView.backgroundColor = parent.readingMode == .horizontal ? .systemBackground : .secondarySystemBackground
            if parent.readingMode == .horizontal {
                pdfView.displayMode = .singlePage
                pdfView.displayDirection = .horizontal
                pdfView.usePageViewController(true, withViewOptions: nil)
            } else {
                pdfView.usePageViewController(false, withViewOptions: nil)
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
                pdfView.layoutIfNeeded()
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
            let relativeZoom = hasDocument && fitScale > 0 ? view.pdfView.scaleFactor / fitScale : 1
            view.setLoading()
            loading = Task { @MainActor [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) {
                    LoadedPDF(document: PDFDocument(url: url))
                }.value
                guard !Task.isCancelled, let self, self.generation == token, let view = self.view else { return }
                self.loading = nil
                guard let document = loaded.document, !document.isLocked, document.pageCount > 0 else {
                    view.setError("This notebook could not be opened. Please try again.")
                    return
                }
                self.isUpdating = true
                self.installedDocument = document
                self.installedPageIDs = self.parent.pageIDs
                view.pdfView.document = document
                let requestedIndex = self.parent.currentPageID.flatMap { self.parent.pageIDs.firstIndex(of: $0) }
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
            reportInteraction()
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
                if self.parent.currentPageID != id {
                    self.parent.currentPageID = id
                }
            }
        }
    }
}

private struct LoadedPDF: @unchecked Sendable {
    let document: PDFDocument?
}

final class PDFReaderView: UIView {
    let pdfView = PDFView()
    let retryButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let errorStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .secondarySystemBackground
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .secondaryLabel
        retryButton.setTitle("Retry", for: .normal)
        errorStack.axis = .vertical
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Fit Page", action: #selector(fitPage), input: "0", modifierFlags: .command)
        ]
    }

    @objc func zoomIn() {
        guard pdfView.document != nil, pdfView.canZoomIn else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
    }

    @objc func zoomOut() {
        guard pdfView.document != nil, pdfView.canZoomOut else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
    }

    @objc func fitPage() {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = true
    }

    func setLoading() {
        pdfView.isHidden = true
        errorStack.isHidden = true
        progress.startAnimating()
    }

    func setReady() {
        progress.stopAnimating()
        errorStack.isHidden = true
        pdfView.isHidden = false
    }

    func setError(_ message: String) {
        progress.stopAnimating()
        pdfView.isHidden = true
        errorLabel.text = message
        errorStack.isHidden = false
    }
}
