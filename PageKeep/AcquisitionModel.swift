import AVFoundation
import Foundation
import Observation
import VisionKit

enum AcquisitionSource {
    case scan
    case importPDF
}

enum AcquisitionPurpose {
    case createNotebook
    case append(UUID)
    case draft

    var notebookID: UUID? {
        if case let .append(id) = self { return id }
        return nil
    }
}

enum AcquisitionResult {
    case saved(SavedNotebook)
    case prepared(PreparedPDF)
}

enum AcquisitionInput {
    case scan(CapturedScan)
    case pdf(URL)
}

@MainActor
@Observable
final class AcquisitionModel {
    enum Phase {
        case opening, scanner, importer, preparing, ready, saving, failed, cameraUnavailable, editing, finished
    }

    let purpose: AcquisitionPurpose
    private(set) var phase: Phase = .opening
    private(set) var prepared: PreparedPDF?
    private(set) var editorDraft: NotebookDraft?
    private(set) var errorMessage: String?
    private(set) var cameraMessage: String?
    private(set) var canOpenSettings = false
    private let store: LibraryStore
    private let prepare: (AcquisitionInput) async throws -> PreparedPDF
    private let onComplete: (AcquisitionResult) -> Void
    private var input: AcquisitionInput?
    private var selectedSource: AcquisitionSource?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(
        store: LibraryStore,
        purpose: AcquisitionPurpose,
        prepare: ((AcquisitionInput) async throws -> PreparedPDF)? = nil,
        onComplete: @escaping (AcquisitionResult) -> Void
    ) {
        self.store = store
        self.purpose = purpose
        self.onComplete = onComplete
        let processor = ScanProcessor()
        self.prepare = prepare ?? { input in
            switch input {
            case let .scan(capture): try await processor.prepare(capture)
            case let .pdf(url): try await store.repository.prepareImport(from: url)
            }
        }
    }

    var isSaving: Bool { phase == .saving }
    var hasPendingPages: Bool { phase == .preparing || prepared != nil || input != nil }
    var blocksDismissal: Bool { isSaving || hasPendingPages }

    func start(_ source: AcquisitionSource) {
        guard selectedSource == nil, phase == .opening else { return }
        choose(source)
    }

    func choose(_ source: AcquisitionSource) {
        guard !isSaving, phase != .finished, phase != .editing else { return }
        selectedSource = source
        errorMessage = nil
        cameraMessage = nil
        canOpenSettings = false
        switch source {
        case .importPDF:
            phase = .importer
        case .scan:
            guard VNDocumentCameraViewController.isSupported else {
                showCameraMessage("Document scanning is unavailable on this device. You can import a PDF instead.")
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                phase = .scanner
            case .notDetermined:
                phase = .opening
                let token = generation
                work = Task {
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    guard generation == token, !Task.isCancelled else { return }
                    if allowed { phase = .scanner } else { showCameraDenied() }
                    work = nil
                }
            case .denied:
                showCameraDenied()
            case .restricted:
                showCameraMessage("Camera access is restricted on this device. You can import a PDF instead.")
            @unknown default:
                showCameraMessage("The camera is unavailable. You can import a PDF instead.")
            }
        }
    }

    private func showCameraMessage(_ message: String) {
        cameraMessage = message
        phase = .cameraUnavailable
    }

    private func showCameraDenied() {
        canOpenSettings = true
        showCameraMessage("Allow camera access in Settings to scan pages, or import a PDF.")
    }

    func receiveImport(_ url: URL) {
        guard phase == .importer else { return }
        input = .pdf(url)
        preparePages()
    }

    func receiveScan(_ scan: CapturedScan) {
        guard phase == .scanner else { return }
        input = .scan(scan)
        preparePages()
    }

    func scannerFailed(_ error: Error) {
        guard phase == .scanner else { return }
        errorMessage = "Scanning failed. \(error.localizedDescription)"
        phase = .failed
    }

    func retry() {
        guard phase == .failed else { return }
        if prepared != nil {
            save()
        } else if input != nil {
            preparePages()
        } else if let selectedSource {
            choose(selectedSource)
        }
    }

    private func preparePages() {
        guard let input else { return }
        work?.cancel()
        let token = UUID()
        generation = token
        phase = .preparing
        errorMessage = nil
        work = Task {
            do {
                let result = try await prepare(input)
                guard generation == token, !Task.isCancelled else {
                    await store.repository.discardPrepared(result)
                    return
                }
                self.input = nil
                work = nil
                switch purpose {
                case .createNotebook:
                    editorDraft = NotebookDraft(
                        details: NotebookDetails(name: result.suggestedName), additions: [result]
                    )
                    phase = .editing
                case .draft:
                    phase = .finished
                    onComplete(.prepared(result))
                case .append:
                    prepared = result
                    phase = .ready
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                work = nil
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    func save() {
        guard phase == .ready || phase == .failed,
              let prepared, let notebookID = purpose.notebookID, !store.isBusy else { return }
        phase = .saving
        errorMessage = nil
        work = Task {
            do {
                let saved = try await store.appendPrepared(prepared, to: notebookID)
                await store.repository.discardPrepared(prepared)
                self.prepared = nil
                work = nil
                phase = .finished
                onComplete(.saved(saved))
            } catch {
                work = nil
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    func editorSaved(_ result: SavedNotebook) {
        guard phase == .editing else { return }
        phase = .finished
        onComplete(.saved(result))
    }

    func cancel() {
        guard !isSaving, phase != .finished else { return }
        generation = UUID()
        work?.cancel()
        work = nil
        input = nil
        phase = .finished
        if let prepared {
            self.prepared = nil
            Task { await store.repository.discardPrepared(prepared) }
        }
        if let editorDraft {
            self.editorDraft = nil
            Task { await editorDraft.discardPendingPages(in: store.repository) }
        }
    }
}
