import SwiftUI
import VisionKit

struct CapturedScan: @unchecked Sendable {
    let scan: VNDocumentCameraScan
}

struct DocumentScanner: UIViewControllerRepresentable {
    let onCapture: (CapturedScan) -> Void
    let onCancel: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ controller: VNDocumentCameraViewController, coordinator: Coordinator) {
        controller.delegate = nil
        coordinator.isActive = false
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var parent: DocumentScanner
        var isActive = true

        init(parent: DocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard isActive else { return }
            isActive = false
            parent.onCapture(CapturedScan(scan: scan))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard isActive else { return }
            isActive = false
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            guard isActive else { return }
            isActive = false
            parent.onFailure(error)
        }
    }
}
