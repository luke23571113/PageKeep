import SwiftUI

struct AcquisitionView: View {
    let store: LibraryStore
    let initialSource: AcquisitionSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: AcquisitionModel
    @State private var showsDiscardConfirmation = false

    init(
        store: LibraryStore,
        purpose: AcquisitionPurpose,
        initialSource: AcquisitionSource,
        onComplete: @escaping (AcquisitionResult) -> Void
    ) {
        self.store = store
        self.initialSource = initialSource
        _model = State(initialValue: AcquisitionModel(store: store, purpose: purpose, onComplete: onComplete))
    }

    private var notebook: Notebook? {
        model.purpose.notebookID.flatMap { store.notebook(id: $0) }
    }

    var body: some View {
        Group {
            if let draft = model.editorDraft {
                NotebookEditorView(store: store, draft: draft) { id, pageID in
                    model.editorSaved(SavedNotebook(notebookID: id, firstAddedPageID: pageID))
                }
            } else {
                acquisitionContent
                    .background {
                        DraftDismissalGuard(
                            isBlocked: model.blocksDismissal,
                            onAttempt: requestCancel,
                            onDismiss: model.cancel
                        )
                    }
                    .confirmationDialog("Discard pending pages?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive, action: cancel)
                        Button("Keep Editing", role: .cancel) { }
                    }
            }
        }
        .task { model.start(initialSource) }
        .onChange(of: model.phase) { _, phase in
            if phase == .finished {
                showsDiscardConfirmation = false
                if case .draft = model.purpose { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var acquisitionContent: some View {
        switch model.phase {
        case .importer:
            PDFImporter(onImport: model.receiveImport, onCancel: {
                guard model.phase == .importer else { return }
                cancel()
            })
                .accessibilityIdentifier("acquisition.pdfPicker")
                .ignoresSafeArea()
        case .scanner:
            DocumentScanner(onCapture: model.receiveScan, onCancel: {
                guard model.phase == .scanner else { return }
                cancel()
            }, onFailure: model.scannerFailed)
                .ignoresSafeArea()
        default:
            acquisitionForm
        }
    }

    private var acquisitionForm: some View {
        NavigationStack {
            Form {
                if let notebook {
                    Section {
                        Text(notebook.name).font(.headline)
                        Text("New pages will be added after page \(notebook.pageCount).")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.phase == .preparing {
                    Section { ProgressView("Preparing pages…") }
                } else if let prepared = model.prepared {
                    Section {
                        Label(prepared.pageCount == 1 ? "1 page ready" : "\(prepared.pageCount) pages ready", systemImage: "doc")
                        Button(action: model.save) {
                            if model.isSaving {
                                ProgressView("Saving…")
                            } else {
                                Text("Add \(prepared.pageCount) \(prepared.pageCount == 1 ? "Page" : "Pages")")
                            }
                        }
                        .accessibilityIdentifier("acquisition.save")
                        .disabled(model.isSaving || store.isBusy)
                    }
                } else if let message = model.cameraMessage {
                    Section {
                        Text(message).foregroundStyle(.secondary)
                        if model.canOpenSettings {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        Button("Import PDF", systemImage: "doc.badge.plus") { model.choose(.importPDF) }
                    }
                } else if model.errorMessage == nil {
                    Section { ProgressView("Opening…") }
                }
                if let message = model.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                        Button("Retry", action: model.retry)
                            .disabled(store.isBusy)
                    }
                }
            }
            .navigationTitle(model.purpose.notebookID == nil ? "New Notebook" : "Add Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestCancel).disabled(model.isSaving)
                }
            }
            .disabled(model.isSaving)
        }
    }

    private func requestCancel() {
        guard !model.isSaving else { return }
        if model.hasPendingPages {
            showsDiscardConfirmation = true
        } else {
            cancel()
        }
    }

    private func cancel() {
        model.cancel()
        dismiss()
    }
}

struct AcquisitionMenuChoices: View {
    let onChoose: (AcquisitionSource) -> Void

    var body: some View {
        Button("Scan Pages", systemImage: "doc.viewfinder") { onChoose(.scan) }
        Button("Import PDF", systemImage: "doc.badge.plus") { onChoose(.importPDF) }
    }
}
