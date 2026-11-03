import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

@MainActor
enum MacFileActions {
    static func choosePDF() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSaveDestination(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name + ".pdf"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func copyPDF(_ source: URL, to destination: URL) async throws {
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let replacement = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
            )
            defer { try? manager.removeItem(at: replacement) }
            let candidate = replacement.appendingPathComponent("notebook.pdf")
            try manager.copyItem(at: source, to: candidate)
            try Task.checkCancellation()
            // The rename replaces the destination only after the complete copy is ready.
            let result = candidate.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    rename(sourcePath!, destinationPath!)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }.value
    }

}

struct MacShareButton: NSViewRepresentable {
    let store: LibraryStore
    let notebookID: UUID
    let onError: (String) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share PDF")!,
            target: context.coordinator, action: #selector(Coordinator.share(_:))
        )
        context.coordinator.button = button
        button.bezelStyle = .toolbar
        button.toolTip = "Share PDF"
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        if context.coordinator.parent.notebookID != notebookID {
            context.coordinator.cancel()
            context.coordinator.button = button
        }
        context.coordinator.parent = self
        button.isEnabled = context.environment.isEnabled && !store.isBusy
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.cancel()
        button.target = nil
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var parent: MacShareButton
        weak var button: NSButton?
        private var generation = UUID()
        private var preparation: Task<Void, Never>?
        private var sharedURL: URL?
        private var picker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var retainedForShare: Coordinator?

        init(parent: MacShareButton) { self.parent = parent }

        @objc func share(_ sender: NSButton) {
            guard sharedURL == nil else { return }
            sender.isEnabled = false
            let token = UUID()
            generation = token
            preparation = Task { @MainActor [weak self, weak sender] in
                guard let self, let sender else { return }
                defer { if self.generation == token { sender.isEnabled = true; self.preparation = nil } }
                do {
                    let url = try await parent.store.shareCopy(of: parent.notebookID)
                    guard !Task.isCancelled, generation == token, sender.window != nil, button === sender else {
                        ShareFileCleanup.remove(url)
                        return
                    }
                    sharedURL = url
                    let picker = NSSharingServicePicker(items: [url])
                    self.picker = picker
                    picker.delegate = self
                    picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
                } catch {
                    if generation == token, !Task.isCancelled { parent.onError(error.localizedDescription) }
                }
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if let service {
                activeService = service
                retainedForShare = self
            } else { cleanUp() }
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService
        ) -> (any NSSharingServiceDelegate)? { self }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { cleanUp() }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            if button?.window != nil { parent.onError(error.localizedDescription) }
            cleanUp()
        }

        func cancel() {
            generation = UUID()
            preparation?.cancel()
            preparation = nil
            picker?.delegate = nil
            button = nil
            if activeService == nil { cleanUp() }
        }

        private func cleanUp() {
            if let sharedURL { ShareFileCleanup.remove(sharedURL) }
            sharedURL = nil
            picker = nil
            activeService?.delegate = nil
            activeService = nil
            retainedForShare = nil
        }
    }
}
