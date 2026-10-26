import XCTest
import UIKit
@testable import PageKeep

@MainActor
final class DraftDismissalGuardTests: XCTestCase {
    func testBlockedDismissalOffersConfirmationAndForwardsCompletedDismissal() {
        let presentation = UIPresentationController(presentedViewController: UIViewController(), presenting: UIViewController())
        let original = DismissalDelegate()
        presentation.delegate = original
        let guardController = DraftDismissalGuard.DismissalController()
        var attempts = 0
        var completed = 0
        guardController.update(isBlocked: true, onAttempt: { attempts += 1 }, onDismiss: { completed += 1 })
        guardController.install(on: presentation)

        XCTAssertFalse(guardController.presentationControllerShouldDismiss(presentation))
        guardController.presentationControllerDidAttemptToDismiss(presentation)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(original.shouldDismissCalls, 0)

        guardController.update(isBlocked: false, onAttempt: { attempts += 1 }, onDismiss: { completed += 1 })
        XCTAssertTrue(guardController.presentationControllerShouldDismiss(presentation))
        guardController.presentationControllerWillDismiss(presentation)
        guardController.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(original.shouldDismissCalls, 1)
        XCTAssertEqual(original.willDismissCalls, 1)
        XCTAssertEqual(original.didDismissCalls, 1)
        XCTAssertEqual(completed, 1)
    }

    func testOriginalDismissalPolicyAndDelegateArePreserved() {
        let presentation = UIPresentationController(presentedViewController: UIViewController(), presenting: UIViewController())
        let original = DismissalDelegate()
        original.allowsDismissal = false
        presentation.delegate = original
        let guardController = DraftDismissalGuard.DismissalController()
        guardController.update(isBlocked: false, onAttempt: {}, onDismiss: {})
        guardController.install(on: presentation)
        XCTAssertFalse(guardController.presentationControllerShouldDismiss(presentation))
        guardController.deactivate()
        XCTAssertTrue(presentation.delegate === original)
        guardController.install(on: presentation)
        XCTAssertTrue(presentation.delegate === original)
    }

    func testReplacingAcquisitionGuardPreservesSwiftUIDelegate() {
        let presentation = UIPresentationController(presentedViewController: UIViewController(), presenting: UIViewController())
        let original = DismissalDelegate()
        presentation.delegate = original
        let acquisition = DraftDismissalGuard.DismissalController()
        acquisition.update(isBlocked: false, onAttempt: {}, onDismiss: {})
        acquisition.install(on: presentation)
        let editor = DraftDismissalGuard.DismissalController()
        editor.update(isBlocked: true, onAttempt: {}, onDismiss: {})
        editor.install(on: presentation)
        acquisition.deactivate()
        XCTAssertTrue(presentation.delegate === editor)
        XCTAssertFalse(editor.presentationControllerShouldDismiss(presentation))
        editor.update(isBlocked: false, onAttempt: {}, onDismiss: {})
        editor.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(original.didDismissCalls, 1)
        editor.deactivate()
        XCTAssertTrue(presentation.delegate === original)
    }

    func testNestedGuardsRestoreOnlyTheirOwnPresentationDelegate() {
        let parentPresentation = UIPresentationController(presentedViewController: UIViewController(), presenting: UIViewController())
        let childPresentation = UIPresentationController(presentedViewController: UIViewController(), presenting: UIViewController())
        let parent = DraftDismissalGuard.DismissalController()
        let child = DraftDismissalGuard.DismissalController()
        parent.update(isBlocked: true, onAttempt: {}, onDismiss: {})
        child.update(isBlocked: false, onAttempt: {}, onDismiss: {})
        parent.install(on: parentPresentation)
        child.install(on: childPresentation)
        child.deactivate()
        XCTAssertTrue(parentPresentation.delegate === parent)
        XCTAssertNil(childPresentation.delegate)
        XCTAssertFalse(parent.presentationControllerShouldDismiss(parentPresentation))
    }
}

@MainActor
private final class DismissalDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    var allowsDismissal = true
    var shouldDismissCalls = 0
    var willDismissCalls = 0
    var didDismissCalls = 0

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        shouldDismissCalls += 1
        return allowsDismissal
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        willDismissCalls += 1
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didDismissCalls += 1
    }
}
