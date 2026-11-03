import AppKit
import SwiftUI

@MainActor
final class MacDraftProtection {
    static let shared = MacDraftProtection()
    var hasChanges = false
    var isSaving = false
    var discard: (() async -> Void)?

    func confirmLeaving(_ finish: @escaping () -> Void) -> Bool {
        guard hasChanges || isSaving else { return true }
        let alert = NSAlert()
        if isSaving {
            alert.messageText = "Please wait for saving to finish."
            alert.informativeText = "Your notebook is still being saved."
            alert.addButton(withTitle: "Keep Editing")
            alert.runModal()
            return false
        }
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your imported pages and unsaved notebook changes will be discarded."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        let cleanup = discard
        hasChanges = false
        Task {
            await cleanup?()
            finish()
        }
        return false
    }
}

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var cloudSync: CloudSyncCoordinator?

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await cloudSync?.refresh() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let protection = MacDraftProtection.shared
        guard protection.hasChanges || protection.isSaving else { return .terminateNow }
        _ = protection.confirmLeaving { sender.reply(toApplicationShouldTerminate: true) }
        if protection.hasChanges || protection.isSaving { return .terminateCancel }
        return .terminateLater
    }
}

struct MacWindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.install(on: window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var previousDelegate: (any NSWindowDelegate)?

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            restore()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func restore() {
            if window?.delegate === self { window?.delegate = previousDelegate }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let canClose = MacDraftProtection.shared.confirmLeaving { [weak sender] in sender?.performClose(nil) }
            guard canClose else { return false }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
