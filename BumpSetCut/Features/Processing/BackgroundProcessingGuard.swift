import UIKit

/// Protects long-running processing from immediate suspension when the app is backgrounded.
/// Uses UIApplication.beginBackgroundTask to request ~30s of continued execution.
/// If background time expires, cancels the processing task and ends the background task.
final class BackgroundProcessingGuard {
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private var onCancel: (@MainActor () -> Void)?

    /// Begin background protection.
    /// `onExpiring` is called on the main thread if background time is about to run out.
    /// The guard will also invoke `onCancel` (if set) to cancel the in-flight processing task.
    @MainActor
    func begin(onExpiring: @escaping @MainActor () -> Void) {
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "VideoProcessing") { [weak self] in
            Task { @MainActor in
                onExpiring()
                self?.onCancel?()
                self?.end()
            }
        }
    }

    /// Register a cancellation closure that will be called if background time expires.
    /// Typically used to cancel the processing Task.
    @MainActor
    func setCancellationHandler(_ handler: @escaping @MainActor () -> Void) {
        self.onCancel = handler
    }

    /// End background protection. Call when processing completes, fails, or is cancelled.
    @MainActor
    func end() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
        onCancel = nil
    }

    deinit {
        let capturedId = taskId
        if capturedId != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(capturedId)
            }
        }
    }
}
