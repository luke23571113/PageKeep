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

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner

        init(parent: DocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onCapture(CapturedScan(scan: scan))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onFailure(error)
        }
    }
}
