//
//  DismissAttemptObserver.swift
//  BumpSetCut
//
//  SwiftUI can block a sheet's swipe-down (interactiveDismissDisabled) but
//  can't tell you it happened. This hooks UIKit's "did attempt to dismiss"
//  callback so a blocked swipe can ask "Discard?" instead of doing nothing.
//

import SwiftUI
import UIKit

extension View {
    /// Runs `onAttempt` when someone swipes down this sheet while its
    /// interactive dismiss is disabled.
    func onDismissAttempt(_ onAttempt: @escaping () -> Void) -> some View {
        background(DismissAttemptObserver(onAttempt: onAttempt))
    }
}

private struct DismissAttemptObserver: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttempt: onAttempt)
    }

    func makeUIViewController(context: Context) -> HookController {
        HookController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: HookController, context: Context) {
        context.coordinator.onAttempt = onAttempt
    }

    /// Sits in front of SwiftUI's own presentation delegate: handles the
    /// dismiss attempt and forwards every other callback untouched, so
    /// interactiveDismissDisabled and the sheet binding keep working.
    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var onAttempt: () -> Void
        weak var forwardee: UIAdaptivePresentationControllerDelegate?

        init(onAttempt: @escaping () -> Void) {
            self.onAttempt = onAttempt
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            forwardee?.presentationControllerDidAttemptToDismiss?(presentationController)
            onAttempt()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            super.responds(to: aSelector) ? nil : forwardee
        }
    }

    final class HookController: UIViewController {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Nearest presentation controller: the sheet this view lives in.
            guard let presentation = presentationController,
                  presentation.delegate !== coordinator else { return }
            coordinator.forwardee = presentation.delegate
            presentation.delegate = coordinator
        }
    }
}
