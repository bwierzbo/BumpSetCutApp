//
//  ProcessingBackgroundKeeper.swift
//  BumpSetCut
//
//  Keeps long-running, user-initiated work alive when the user leaves the
//  app, on iOS 26+ via BGContinuedProcessingTask: the system shows its own
//  live progress UI (with a cancel affordance) and lets the work keep
//  running in the background. Two instances cover the app's long jobs —
//  video processing (which additionally checkpoints for resume) and Photos
//  imports (which can't resume, so continuation is their only lifeline).
//  Older iOS falls back to the ~30s grace window.
//
//  Registration must happen before the first submit — BumpSetCutApp.init
//  calls `registerAll()` at launch.
//

import BackgroundTasks
import Foundation
import Observation

@MainActor
@Observable
final class ProcessingBackgroundKeeper {

    /// Continuation for rally-detection processing runs.
    static let processing = ProcessingBackgroundKeeper(
        identifier: "app.BumpSetCut.processing",
        title: "Detecting rallies"
    )

    /// Continuation for Photos/iCloud video imports.
    static let importing = ProcessingBackgroundKeeper(
        identifier: "app.BumpSetCut.import",
        title: "Importing video"
    )

    /// True while a continued-processing task is keeping us alive — legacy
    /// 30s-guard expiry must NOT cancel the work, and "keep the app open"
    /// copy switches to "free to leave the app".
    private(set) var isActive = false

    @ObservationIgnored private var task: AnyObject?
    /// Called on system expiration, BEFORE the grace period ends — processing
    /// uses it to request a pipeline checkpoint.
    @ObservationIgnored var onExpiration: (@MainActor () -> Void)?
    /// Called when the user cancels from the system progress UI.
    @ObservationIgnored var onSystemCancel: (@MainActor () -> Void)?

    private let identifier: String
    private let title: String

    private init(identifier: String, title: String) {
        self.identifier = identifier
        self.title = title
    }

    /// Register both launch handlers. Must run during app launch, before any
    /// submit. No-op below iOS 26.
    static func registerAll() {
        guard #available(iOS 26.0, *) else { return }
        for keeper in [processing, importing] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: keeper.identifier, using: .main) { task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MainActor.assumeIsolated {
                    keeper.adopt(continued)
                }
            }
        }
    }

    /// Submit a continued-processing request for the job that just started.
    /// Must be called while the app is foregrounded. Failure is fine — the
    /// job simply stays foreground-bound like before.
    func begin(subtitle: String) {
        guard #available(iOS 26.0, *) else { return }
        guard task == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("⚠️ ProcessingBackgroundKeeper(\(identifier)): submit failed — \(error.localizedDescription)")
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
                // Give the job a beat to save state, then wind the task down.
                self.onExpiration?()
                self.finish(success: false)
            }
        }
    }

    /// Mirror the job's progress into the system UI.
    func updateProgress(_ fraction: Double, subtitle: String) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
        let clamped = Int64(min(100, max(0, fraction * 100)))
        if continued.progress.completedUnitCount != clamped {
            continued.progress.completedUnitCount = clamped
            continued.updateTitle(title, subtitle: "\(subtitle) · \(clamped)%")
        }
        // The system cancels the task's progress when the user taps cancel
        // in its UI — surface that as a job cancel exactly once.
        if continued.progress.isCancelled {
            let handler = onSystemCancel
            finish(success: false)
            handler?()
        }
    }

    /// End the continued-processing task (job finished, failed, or was
    /// cancelled). Safe to call when none is active.
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
