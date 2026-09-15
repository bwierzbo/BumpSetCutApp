//
//  FolderReelExportSheet.swift
//  BumpSetCut
//
//  Stitches favorites clips into ONE highlight video saved to Photos (with
//  share). Community posting is NOT stitched — it goes through the
//  multi-rally ShareRallySheet instead. Mirrors the RallyExportProgress
//  pattern: storage preflight, background task, cancel, retry, haptics.
//

import SwiftUI
import AVFoundation
import UIKit

struct FolderReelExportSheet: View {
    let folderName: String
    let clips: [VideoExporter.StitchClip]

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
                            cancelExport()
                        } label: {
                            Text("Cancel")
                                .bscFont(size: 17, weight: .semibold)
                                .foregroundColor(.bscErrorText)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier(AccessibilityID.Export.cancelButton)
                        .accessibilityLabel("Cancel export")

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
            .navigationTitle("Export Highlight Video")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            startExport()
        }
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
                ProgressView(value: exportProgress)
                    .progressViewStyle(CircularProgressViewStyle(tint: .bscTealText))
                    .scaleEffect(2.0)
            }
        }
    }

    private var statusText: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text(exportStatus == .completed ? "Reel ready!" : "Stitching \(folderName)…")
                .bscFont(size: 17, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            if exportStatus == .exporting {
                Text("\(clips.count) \(clips.count == 1 ? "clip" : "clips") · \(Int(exportProgress * 100))%")
                    .bscFont(size: 17)
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
                .accessibilityLabel("Share highlight reel")
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
                .accessibilityLabel("Retry export")

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

    private func cancelExport() {
        exportTask?.cancel()
        dismiss()
    }

    private func startExport() {
        exportTask?.cancel()
        exportTask = Task {
            await performExport()
        }
    }

    private func performExport() async {
        exportStatus = .preparing
        exportProgress = 0.0

        // Pre-flight storage check: the stitched reel re-encodes every clip.
        let totalSourceBytes = clips.reduce(Int64(0)) { $0 + StorageChecker.getFileSize(at: $1.url) }
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: max(totalSourceBytes, 50_000_000))
        if !storageCheck.isSufficient {
            storageError = storageCheck.shortMessage ?? "Not enough storage space"
            return
        }

        // Survive app backgrounding during the stitch.
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

            let exporter = VideoExporter()
            let addWatermark = SubscriptionService.shared.shouldAddWatermark
            let progressHandler: @Sendable (Double) -> Void = { progress in
                Task { @MainActor in
                    exportProgress = progress
                }
            }

            let url = try await exporter.exportStitchedClipsToPhotoLibrary(
                clips, addWatermark: addWatermark, progressHandler: progressHandler
            )
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

    /// Sweep stitched temp files stranded by a cancelled/failed export.
    private func cleanupOrphanedStitchFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.lastPathComponent.hasPrefix("stitched_rallies_") && file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
