//
//  ProcessingBackgroundKeeper.swift
//  BumpSetCut
//
//  Keeps video processing alive when the user leaves the app, on iOS 26+
//  via BGContinuedProcessingTask: the system shows its own live progress UI
//  (with a cancel affordance) and lets user-initiated work keep running in
//  the background. On expiration the pipeline writes a resume checkpoint so
//  nothing is lost. Older iOS falls back to the ~30s grace window +
//  checkpoint-on-background (see ProcessingCoordinator).
//
//  Registration must happen before the first submit — BumpSetCutApp.init
//  calls `register()` at launch.
//

import BackgroundTasks
import Foundation

@MainActor
final class ProcessingBackgroundKeeper {

    static let shared = ProcessingBackgroundKeeper()
    static let taskIdentifier = "app.BumpSetCut.processing"

    /// True while a continued-processing task is keeping us alive — the
    /// legacy 30s-guard expiry must NOT cancel processing in that case.
    private(set) var isActive = false

    private var task: AnyObject?
    /// Called on system expiration, BEFORE the grace period ends — the
    /// coordinator uses it to request a pipeline checkpoint.
    var onExpiration: (@MainActor () -> Void)?
    /// Called when the user cancels from the system progress UI.
    var onSystemCancel: (@MainActor () -> Void)?

    private init() {}

    /// Register the launch handler. Must run during app launch, before any
    /// submit. No-op below iOS 26.
    static func register() {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                ProcessingBackgroundKeeper.shared.adopt(continued)
            }
        }
    }

    /// Submit a continued-processing request for the job that just started.
    /// Must be called while the app is foregrounded. Failure is fine — the
    /// job simply stays foreground-bound like before.
    func begin(videoName: String) {
        guard #available(iOS 26.0, *) else { return }
        guard task == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Detecting rallies",
            subtitle: videoName
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("⚠️ ProcessingBackgroundKeeper: submit failed — \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ continued: BGContinuedProcessingTask) {
        task = continued
        isActive = true
        continued.progress.totalUnitCount = 100
        continued.progress.completedUnitCount = 0
        continued.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Ask the pipeline to checkpoint at the next idle frame, then
                // let the coordinator wind the run down gracefully.
                self.onExpiration?()
                self.finish(success: false)
            }
        }
    }

    /// Mirror the coordinator's progress into the system UI.
    func updateProgress(_ fraction: Double, videoName: String) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
        let clamped = Int64(min(100, max(0, fraction * 100)))
        if continued.progress.completedUnitCount != clamped {
            continued.progress.completedUnitCount = clamped
            continued.updateTitle("Detecting rallies", subtitle: "\(videoName) · \(clamped)%")
        }
        // The system cancels the task's progress when the user taps cancel
        // in its UI — surface that as a processing cancel exactly once.
        if continued.progress.isCancelled {
            let handler = onSystemCancel
            finish(success: false)
            handler?()
        }
    }

    /// End the continued-processing task (processing finished, failed, or
    /// was cancelled). Safe to call when none is active.
    func finish(success: Bool) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else {
            task = nil
            isActive = false
            return
        }
        task = nil
        isActive = false
        continued.setTaskCompleted(success: success)
    }
}
