import PDFKit
import SwiftUI

struct PDFReader: UIViewRepresentable {
    let url: URL
    let pageIDs: [UUID]
    @Binding var currentPageID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PDFReaderView {
        let view = PDFReaderView()
        context.coordinator.view = view
        view.retryButton.addTarget(context.coordinator, action: #selector(Coordinator.retry), for: .touchUpInside)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view.pdfView)
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ view: PDFReaderView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: PDFReaderView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: PDFReader
        weak var view: PDFReaderView?
        var loadedURL: URL?
        var loading: Task<Void, Never>?
        private var generation = UUID()
        private var isUpdating = false

        init(parent: PDFReader) {
            self.parent = parent
        }

        func update(_ parent: PDFReader) {
            self.parent = parent
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
                view.pdfView.document = document
                let requestedIndex = self.parent.currentPageID.flatMap { self.parent.pageIDs.firstIndex(of: $0) }
                let index = min(requestedIndex ?? oldIndex, document.pageCount - 1)
                if let page = document.page(at: max(0, index)) {
                    view.pdfView.go(to: page)
                }
                self.isUpdating = false
                view.setReady()
                self.pageChanged()
            }
        }

        @objc func pageChanged() {
            guard !isUpdating, let view,
                  let document = view.pdfView.document,
                  let page = view.pdfView.currentPage else { return }
            let index = document.index(for: page)
            guard parent.pageIDs.indices.contains(index) else { return }
            let id = parent.pageIDs[index]
            let token = generation
            let previousSelection = parent.currentPageID
            // PDFKit can notify while SwiftUI is updating this view.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token,
                      self.parent.currentPageID == previousSelection,
                      let pdfView = self.view?.pdfView,
                      let document = pdfView.document,
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
