import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

enum AcquisitionSource {
    case scan
    case importPDF
}

struct AcquisitionView: View {
    let store: LibraryStore
    let notebookID: UUID?
    let initialSource: AcquisitionSource?
    let onSaved: (UUID, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showScanner = false
    @State private var showImporter = false
    @State private var started = false
    @State private var prepared: PreparedPDF?
    @State private var capturedScan: CapturedScan?
    @State private var importedURL: URL?
    @State private var name = "Untitled Notebook"
    @State private var errorMessage: String?
    @State private var cameraMessage: String?
    @State private var canOpenSettings = false
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var work: Task<Void, Never>?
    private let scanProcessor = ScanProcessor()

    private var notebook: Notebook? {
        notebookID.flatMap { store.notebook(id: $0) }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let notebook {
                    Section {
                        Text(notebook.name).font(.headline)
                        Text("New pages will be added after page \(notebook.pageCount).")
                            .foregroundStyle(.secondary)
                    }
                }

                if isPreparing {
                    Section {
                        ProgressView("Preparing pages…")
                    }
                } else if let prepared {
                    Section {
                        if notebookID == nil {
                            TextField("Notebook name", text: $name)
                                .accessibilityIdentifier("acquisition.name")
                        }
                        Label(prepared.pageCount == 1 ? "1 page ready" : "\(prepared.pageCount) pages ready", systemImage: "doc")
                    } footer: {
                        if notebookID == nil && trimmedName.isEmpty {
                            Text("Enter a notebook name to save.")
                        }
                    }

                    Section {
                        Button {
                            save(prepared)
                        } label: {
                            if isSaving {
                                ProgressView("Saving…")
                            } else {
                                Text(notebookID == nil ? "Save Notebook" : "Add \(prepared.pageCount) \(prepared.pageCount == 1 ? "Page" : "Pages")")
                            }
                        }
                        .accessibilityIdentifier("acquisition.save")
                        .disabled(isSaving || store.isBusy || (notebookID == nil && trimmedName.isEmpty))
                    }
                } else {
                    sourceSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if !isPreparing && !isSaving && (prepared != nil || capturedScan != nil || importedURL != nil) {
                            Button("Retry") {
                                if let prepared {
                                    save(prepared)
                                } else {
                                    preparePages()
                                }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }
            }
            .navigationTitle(notebookID == nil ? "New Notebook" : "Add Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
        .interactiveDismissDisabled(isSaving)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { capture in
                showScanner = false
                capturedScan = capture
                importedURL = nil
                preparePages()
            } onCancel: {
                showScanner = false
                cancel()
            } onFailure: { error in
                showScanner = false
                errorMessage = "Scanning failed. \(error.localizedDescription)"
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importedURL = url
                capturedScan = nil
                preparePages()
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    errorMessage = "The PDF could not be opened. \(error.localizedDescription)"
                }
            }
        }
        .task {
            guard !started else { return }
            started = true
            if let initialSource {
                choose(initialSource)
            }
        }
        .onDisappear {
            if !showScanner {
                work?.cancel()
                discardPrepared()
            }
        }
    }

    private var sourceSection: some View {
        Section {
            Button { choose(.scan) } label: {
                Label("Scan Pages", systemImage: "doc.viewfinder")
            }
            Button { choose(.importPDF) } label: {
                Label("Import PDF", systemImage: "doc.badge.plus")
            }
            if let cameraMessage {
                Text(cameraMessage).foregroundStyle(.secondary)
                if canOpenSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }
        }
    }

    private func choose(_ source: AcquisitionSource) {
        errorMessage = nil
        switch source {
        case .importPDF:
            showImporter = true
        case .scan:
            cameraMessage = nil
            canOpenSettings = false
            guard VNDocumentCameraViewController.isSupported else {
                cameraMessage = "Document scanning is unavailable on this device. You can import a PDF instead."
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                showScanner = true
            case .notDetermined:
                work = Task {
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    guard !Task.isCancelled else { return }
                    if allowed {
                        showScanner = true
                    } else {
                        showCameraDenied()
                    }
                }
            case .denied:
                showCameraDenied()
            case .restricted:
                cameraMessage = "Camera access is restricted on this device. You can import a PDF instead."
            @unknown default:
                cameraMessage = "The camera is unavailable. You can import a PDF instead."
            }
        }
    }

    private func showCameraDenied() {
        cameraMessage = "Allow camera access in Settings to scan pages, or import a PDF."
        canOpenSettings = true
    }

    private func preparePages() {
        work?.cancel()
        isPreparing = true
        errorMessage = nil
        let capture = capturedScan
        let sourceURL = importedURL
        work = Task {
            do {
                let result: PreparedPDF
                if let capture {
                    result = try await scanProcessor.prepare(capture)
                } else if let sourceURL {
                    result = try await store.repository.prepareImport(from: sourceURL)
                } else {
                    isPreparing = false
                    return
                }
                if Task.isCancelled {
                    await store.repository.discardPrepared(result)
                    return
                }
                prepared = result
                name = result.suggestedName
                capturedScan = nil
                importedURL = nil
                isPreparing = false
            } catch {
                guard !Task.isCancelled else { return }
                isPreparing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save(_ prepared: PreparedPDF) {
        isSaving = true
        errorMessage = nil
        let existingCount = notebook?.pageCount ?? 0
        work = Task {
            do {
                let id = try await store.savePrepared(prepared, name: trimmedName, notebookID: notebookID)
                let firstPageID = store.notebook(id: id)?.pages.dropFirst(existingCount).first?.id
                await store.repository.discardPrepared(prepared)
                self.prepared = nil
                isSaving = false
                onSaved(id, firstPageID)
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        work?.cancel()
        discardPrepared()
        capturedScan = nil
        dismiss()
    }

    private func discardPrepared() {
        guard let prepared else { return }
        self.prepared = nil
        Task { await store.repository.discardPrepared(prepared) }
    }
}
