import SwiftUI
import UIKit

// SwiftUI can block a sheet swipe, but UIKit also tells us when to offer Discard Changes.
struct DraftDismissalGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    let onAttempt: () -> Void
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> DismissalController {
        let controller = DismissalController()
        controller.update(isBlocked: isBlocked, onAttempt: onAttempt, onDismiss: onDismiss)
        return controller
    }

    func updateUIViewController(_ controller: DismissalController, context: Context) {
        controller.update(isBlocked: isBlocked, onAttempt: onAttempt, onDismiss: onDismiss)
    }

    static func dismantleUIViewController(_ controller: DismissalController, coordinator: ()) {
        controller.deactivate()
    }

    final class DismissalController: UIViewController, UIAdaptivePresentationControllerDelegate {
        private weak var guardedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var isActive = true
        var isBlocked = false
        var onAttempt: () -> Void = {}
        var onDismiss: () -> Void = {}

        func update(isBlocked: Bool, onAttempt: @escaping () -> Void, onDismiss: @escaping () -> Void) {
            self.isBlocked = isBlocked
            self.onAttempt = onAttempt
            self.onDismiss = onDismiss
            DispatchQueue.main.async { [weak self] in self?.installDelegate() }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installDelegate()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installDelegate()
        }

        private func installDelegate() {
            guard isActive else { return }
            var controller: UIViewController? = self
            while let current = controller {
                if let presenter = current.presentingViewController,
                   presenter.presentedViewController === current,
                   let presentation = current.presentationController {
                    install(on: presentation)
                    return
                }
                controller = current.parent
            }
        }

        func install(on presentation: UIPresentationController) {
            guard isActive, guardedPresentation !== presentation else { return }
            restoreDelegate()
            guardedPresentation = presentation
            if let previousGuard = presentation.delegate as? DismissalController {
                // A new root can replace the acquisition guard before the old one is removed.
                previousDelegate = previousGuard.previousDelegate
                previousGuard.deactivate()
            } else {
                previousDelegate = presentation.delegate
            }
            presentation.delegate = self
        }

        func deactivate() {
            isActive = false
            restoreDelegate()
        }

        private func restoreDelegate() {
            if guardedPresentation?.delegate === self {
                guardedPresentation?.delegate = previousDelegate
            }
            guardedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            guard !isBlocked else { return false }
            return previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isBlocked {
                onAttempt()
            } else {
                previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
            }
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
            onDismiss()
        }
    }
}
