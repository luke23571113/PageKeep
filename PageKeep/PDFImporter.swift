import SwiftUI
import UniformTypeIdentifiers

struct PDFImporter: UIViewControllerRepresentable {
    let onImport: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        coordinator.isActive = false
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: PDFImporter
        var isActive = true

        init(parent: PDFImporter) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard isActive else { return }
            isActive = false
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onImport(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard isActive else { return }
            isActive = false
            parent.onCancel()
        }
    }
}
