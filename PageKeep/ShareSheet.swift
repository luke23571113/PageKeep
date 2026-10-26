import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss

    init(url: URL, onError: @escaping (Error) -> Void = { _ in }) {
        self.url = url
        self.onError = onError
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "share.sheet"
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in
                guard coordinator.finish() else { return }
                if let error {
                    onError(error)
                }
                dismiss()
            }
        }
        // SwiftUI presents this as a sheet; the anchor also covers iPad popovers.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.maxY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        if controller.presentedViewController == nil {
            coordinator.cleanup()
        }
    }

    final class Coordinator {
        let url: URL
        private var cleanedUp = false
        private var completed = false

        init(url: URL) {
            self.url = url
        }

        func finish() -> Bool {
            guard !completed else { return false }
            completed = true
            cleanup()
            return true
        }

        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            ShareFileCleanup.remove(url)
        }
    }
}
