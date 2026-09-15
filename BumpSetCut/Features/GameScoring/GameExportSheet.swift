//
//  GameExportSheet.swift
//  BumpSetCut
//
//  Exports the full scored game as ONE stitched video with the running
//  scoreboard burned in, saved to Photos. Mirrors the highlight export
//  pattern: storage preflight, progress ring, cancel, retry, share.
//

import SwiftUI
import AVFoundation
import UIKit

struct GameExportSheet: View {
    let gameName: String
    let clips: [VideoExporter.StitchClip]
    let overlays: [VideoExporter.GameScoreOverlay?]

    @Environment(\.dismiss) private var dismiss
    @State private var exportStatus: RallyExportStatus = .preparing
    @State private var exportProgress: Double = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var storageError: String?
    @State private var exportedURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xxl) {
                Spacer()

                if let storageError {
                    storageErrorView(message: storageError)
                    Spacer()
                } else {
                    switch exportStatus {
                    case .preparing, .exporting:
                        progressIndicator
                        statusText
                        Spacer()
                        Button {
                            exportTask?.cancel()
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .bscFont(size: 17, weight: .semibold)
                                .foregroundColor(.bscErrorText)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier(AccessibilityID.Export.cancelButton)

                    case .completed:
                        progressIndicator
                        statusText
                        successView
                        Spacer()

                    case .failed(let errorMessage):
                        failedView(errorMessage: errorMessage)
                        Spacer()
                    }
                }
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("Export Scored Game")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { startExport() }
        .onDisappear {
            exportTask?.cancel()
            cleanupExportedFile()
        }
        .interactiveDismissDisabled(exportStatus == .exporting || exportStatus == .preparing)
    }

    private var progressIndicator: some View {
        VStack(spacing: BSCSpacing.lg) {
            if exportStatus == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .bscFont(size: 60)
                    .foregroundColor(.bscSuccessText)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.bscSurfaceGlass)
                        .frame(width: 148, height: 148)
                    BSCExportProgressRing(progress: exportProgress)
                }
            }
        }
    }

    private var statusText: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text(exportStatus == .completed ? "Game video ready!" : "Building \(gameName)…")
                .bscFont(size: 20, weight: .bold)
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            if exportStatus == .exporting {
                Label("\(clips.count) rallies · scoreboard included", systemImage: "sportscourt")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
            } else if exportStatus == .preparing {
                Text("Preparing rallies…")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
            }
        }
    }

    private var successView: some View {
        VStack(spacing: BSCSpacing.lg) {
            Text("Saved to Photos")
                .bscFont(size: 20, weight: .semibold)
                .foregroundColor(.bscSuccessText)

            if exportedURL != nil {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .bscFont(size: 17, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .padding(.horizontal, BSCSpacing.xxl)
                        .padding(.vertical, BSCSpacing.md)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient.bscPrimaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                }
                .accessibilityIdentifier(AccessibilityID.Export.shareButton)
            }

            Button {
                cleanupExportedFile()
                dismiss()
            } label: {
                Text("Done")
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(AccessibilityID.Export.doneButton)
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportedURL {
                ActivityViewController(activityItems: [exportedURL])
            }
        }
    }

    private func storageErrorView(message: String) -> some View {
        VStack(spacing: BSCSpacing.xl) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .bscFont(size: 60)
                .foregroundColor(.bscWarningText)

            VStack(spacing: BSCSpacing.sm) {
                Text("Not Enough Storage")
                    .bscFont(size: 20, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                Text(message)
                    .bscFont(size: 17)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
            } label: {
                Text("Dismiss")
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscErrorText)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
        }
    }

    private func failedView(errorMessage: String) -> some View {
        VStack(spacing: BSCSpacing.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .bscFont(size: 60)
                .foregroundColor(.bscError)

            VStack(spacing: BSCSpacing.sm) {
                Text("Export Failed")
                    .bscFont(size: 20, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                Text(errorMessage)
                    .bscFont(size: 17)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: BSCSpacing.md) {
                Button {
                    storageError = nil
                    exportStatus = .preparing
                    startExport()
                } label: {
                    Text("Retry")
                        .bscFont(size: 17, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .padding(.horizontal, BSCSpacing.xxl)
                        .padding(.vertical, BSCSpacing.md)
                        .background(LinearGradient.bscPrimaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                }
                .accessibilityIdentifier(AccessibilityID.Export.retryButton)

                Button {
                    dismiss()
                } label: {
                    Text("Dismiss")
                        .bscFont(size: 17, weight: .semibold)
                        .foregroundColor(.bscErrorText)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Export

    private func startExport() {
        exportTask?.cancel()
        exportTask = Task { await performExport() }
    }

    private func performExport() async {
        exportStatus = .preparing
        exportProgress = 0.0

        // The whole game re-encodes: preflight against the source size.
        let sourceBytes = clips.first.map { StorageChecker.getFileSize(at: $0.url) } ?? 0
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: max(sourceBytes, 100_000_000))
        if !storageCheck.isSufficient {
            storageError = storageCheck.shortMessage ?? "Not enough storage space"
            return
        }

        let bgTaskId = UIApplication.shared.beginBackgroundTask {
            self.exportTask?.cancel()
        }
        defer {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            }
        }

        do {
            exportStatus = .exporting
            let addWatermark = SubscriptionService.shared.shouldAddWatermark

            let url = try await VideoExporter().exportScoredGameToPhotoLibrary(
                clips: clips,
                overlays: overlays,
                addWatermark: addWatermark
            ) { progress in
                Task { @MainActor in
                    exportProgress = progress
                }
            }
            try Task.checkCancellation()
            exportedURL = url
            exportProgress = 1.0
            exportStatus = .completed
            UINotificationFeedbackGenerator.success()
        } catch is CancellationError {
            cleanupOrphanedStitchFiles()
        } catch {
            cleanupOrphanedStitchFiles()
            if StorageChecker.isStorageError(error) {
                storageError = "Your device ran out of storage during export. Free up space and try again."
            } else {
                exportStatus = .failed(error.localizedDescription)
            }
            UINotificationFeedbackGenerator.error()
        }
    }

    private func cleanupExportedFile() {
        if let exportedURL {
            try? FileManager.default.removeItem(at: exportedURL)
        }
        exportedURL = nil
    }

    private func cleanupOrphanedStitchFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.lastPathComponent.hasPrefix("stitched_rallies_") && file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
