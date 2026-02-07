import UIKit

/// Protects long-running processing from immediate suspension when the app is backgrounded.
/// Uses UIApplication.beginBackgroundTask to request ~30s of continued execution.
/// If background time expires, calls the expiration handler and ends the task.
final class BackgroundProcessingGuard {
    private var taskId: UIBackgroundTaskIdentifier = .invalid

    /// Begin background protection.
    /// `onExpiring` is called on the main thread if background time is about to run out.
    @MainActor
    func begin(onExpiring: @escaping @MainActor () -> Void) {
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "VideoProcessing") { [weak self] in
            Task { @MainActor in
                onExpiring()
                self?.end()
            }
        }
    }

    /// End background protection. Call when processing completes, fails, or is cancelled.
    @MainActor
    func end() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
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
