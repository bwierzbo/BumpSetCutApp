import SwiftUI
import AVFoundation
import UIKit

// MARK: - Rally Export Progress

struct RallyExportProgress: View {
    let exportType: RallyExportType
    let savedRallies: [Int]
    let processingMetadata: ProcessingMetadata?
    let videoMetadata: VideoMetadata
    let trimAdjustments: [Int: RallyTrimAdjustment]
    @Binding var isExporting: Bool
    @Binding var exportProgress: Double

    @Environment(\.dismiss) private var dismiss
    @State private var exportStatus: RallyExportStatus = .preparing
    @State private var exportedCount = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var storageError: String?
    @State private var exportedURLs: [URL] = []
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
                        Button("Cancel") {
                            cancelExport()
                        }
                        .font(.headline)
                        .foregroundColor(.bscError)
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
            .navigationTitle(exportType.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            startExport()
        }
        .onDisappear {
            exportTask?.cancel()
            cleanupExportedFiles()
        }
        .interactiveDismissDisabled(exportStatus == .exporting || exportStatus == .preparing)
    }

    private var progressIndicator: some View {
        VStack(spacing: BSCSpacing.lg) {
            if exportStatus == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.bscSuccess)
            } else {
                ProgressView(value: exportProgress)
                    .progressViewStyle(CircularProgressViewStyle(tint: exportType == .individual ? .bscPrimary : .bscTeal))
                    .scaleEffect(2.0)
            }
        }
    }

    private var statusText: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text(exportStatus.message)
                .font(.headline)
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            if exportStatus == .exporting {
                if exportType == .individual {
                    Text("\(exportedCount) of \(savedRallies.count) rallies")
                        .font(.body)
                        .foregroundColor(.bscTextSecondary)
                } else {
                    Text("\(Int(exportProgress * 100))%")
                        .font(.body)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }

    private var successView: some View {
        VStack(spacing: BSCSpacing.lg) {
            Text("Saved to Photos")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.bscSuccess)

            if !exportedURLs.isEmpty {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.bscTextInverse)
                        .padding(.horizontal, BSCSpacing.xxl)
                        .padding(.vertical, BSCSpacing.md)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient.bscPrimaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                }
                .accessibilityIdentifier(AccessibilityID.Export.shareButton)
                .accessibilityLabel("Share exported videos")
            }

            Button("Done") {
                cleanupExportedFiles()
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.bscTextSecondary)
            .accessibilityIdentifier(AccessibilityID.Export.doneButton)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: exportedURLs)
        }
    }

    private func storageErrorView(message: String) -> some View {
        VStack(spacing: BSCSpacing.xl) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.bscWarning)

            VStack(spacing: BSCSpacing.sm) {
                Text("Not Enough Storage")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.bscTextPrimary)

                Text(message)
                    .font(.body)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Dismiss") {
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.bscError)
        }
    }

    private func failedView(errorMessage: String) -> some View {
        VStack(spacing: BSCSpacing.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.bscError)

            VStack(spacing: BSCSpacing.sm) {
                Text("Export Failed")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.bscTextPrimary)

                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: BSCSpacing.md) {
                Button("Retry") {
                    storageError = nil
                    startExport()
                }
                .font(.headline)
                .foregroundColor(.bscTextInverse)
                .padding(.horizontal, BSCSpacing.xxl)
                .padding(.vertical, BSCSpacing.md)
                .background(LinearGradient.bscPrimaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                .accessibilityIdentifier(AccessibilityID.Export.retryButton)
                .accessibilityLabel("Retry export")

                Button("Dismiss") {
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.bscError)
            }
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        isExporting = false
        dismiss()
    }

    private func startExport() {
        guard !isExporting else { return }
        exportTask?.cancel()
        exportTask = Task {
            await performExport()
        }
    }

    private func performExport() async {
        guard let metadata = processingMetadata else { return }

        await MainActor.run {
            isExporting = true
            exportStatus = .preparing
            exportProgress = 0.0
        }

        // Pre-flight storage check
        let videoSize = StorageChecker.getFileSize(at: videoMetadata.originalURL)
        let estimatedOutputSize = Int64(Double(videoSize) * 0.5) // Rallies are a fraction of original
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: estimatedOutputSize)
        if !storageCheck.isSufficient {
            await MainActor.run {
                storageError = storageCheck.shortMessage ?? "Not enough storage space"
                isExporting = false
            }
            return
        }

        // Register background task so export survives app backgrounding
        let bgTaskId = UIApplication.shared.beginBackgroundTask {
            // Expiration handler -- cancel if system reclaims
            self.exportTask?.cancel()
        }

        // Track temp files for cleanup on cancel/failure
        let tempFiles: [URL] = []

        do {
            await MainActor.run {
                exportStatus = .exporting
            }

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            let videoDuration = try await CMTimeGetSeconds(asset.load(.duration))
            let exporter = VideoExporter()
            let addWatermark = SubscriptionService.shared.shouldAddWatermark
            let rawSegments = savedRallies.compactMap { index in
                index < metadata.rallySegments.count ? (index, metadata.rallySegments[index]) : nil
            }

            // Apply per-rally trim adjustments, filtering out invalid ranges
            let selectedSegments = rawSegments.compactMap { (rallyIndex, segment) -> RallySegment? in
                guard let adj = trimAdjustments[rallyIndex] else { return segment }
                let adjustedStart = max(0, segment.startTime - adj.before)
                let adjustedEnd = min(videoDuration, segment.endTime + adj.after)
                // Skip segments where trim adjustments create invalid ranges
                guard adjustedStart < adjustedEnd else { return nil }
                return segment.withAdjustedTimes(
                    startSeconds: adjustedStart,
                    endSeconds: adjustedEnd
                )
            }

            if exportType == .individual {
                // Export individual videos
                for (index, segment) in selectedSegments.enumerated() {
                    try Task.checkCancellation()

                    let progress = Double(index) / Double(selectedSegments.count)
                    await MainActor.run {
                        exportProgress = progress
                        exportedCount = index
                    }

                    let url = try await exporter.exportRallyToPhotoLibrary(asset: asset, rally: segment, index: index, addWatermark: addWatermark)
                    await MainActor.run {
                        exportedURLs.append(url)
                    }
                }
            } else {
                // Export stitched video with real progress polling
                let url = try await exporter.exportStitchedRalliesToPhotoLibrary(
                    asset: asset,
                    rallies: selectedSegments,
                    addWatermark: addWatermark
                ) { progress in
                    Task { @MainActor in
                        exportProgress = progress
                    }
                }
                await MainActor.run {
                    exportedURLs.append(url)
                }
            }

            await MainActor.run {
                exportProgress = 1.0
                exportStatus = .completed
                isExporting = false
            }

        } catch is CancellationError {
            // User cancelled -- clean up temp files
            cleanupTempFiles(tempFiles)
            cleanupOrphanedRallyFiles()
            await MainActor.run {
                isExporting = false
            }
        } catch {
            // Export failed -- clean up temp files
            cleanupTempFiles(tempFiles)
            cleanupOrphanedRallyFiles()
            await MainActor.run {
                if StorageChecker.isStorageError(error) {
                    storageError = "Your device ran out of storage during export. Free up space and try again."
                } else {
                    exportStatus = .failed(error.localizedDescription)
                }
                isExporting = false
            }
        }

        // End background task
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }
    }

    /// Remove specific temp files tracked during export
    private func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Clean up exported temp files kept for sharing
    private func cleanupExportedFiles() {
        for url in exportedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        exportedURLs.removeAll()
    }

    /// Clean up orphaned rally_* temp files in the Documents directory
    private func cleanupOrphanedRallyFiles() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.lastPathComponent.hasPrefix("rally_") && file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
        // Also clean stitched temp files in tmp directory
        let tmpDir = FileManager.default.temporaryDirectory
        guard let tmpContents = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for file in tmpContents where file.lastPathComponent.hasPrefix("stitched_rallies_") && file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Export Status

enum RallyExportStatus: Equatable {
    case preparing
    case exporting
    case completed
    case failed(String)

    var message: String {
        switch self {
        case .preparing:
            return "Preparing export..."
        case .exporting:
            return "Exporting rallies..."
        case .completed:
            return "Export complete!"
        case .failed(let error):
            return "Export failed: \(error)"
        }
    }
}

// MARK: - Activity View Controller

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    RallyExportProgress(
        exportType: .individual,
        savedRallies: [0, 1, 2],
        processingMetadata: nil,
        videoMetadata: VideoMetadata(
            fileName: "test.mp4",
            customName: nil,
            folderPath: "",
            createdDate: Date(),
            fileSize: 0,
            duration: 60.0
        ),
        trimAdjustments: [:],
        isExporting: .constant(true),
        exportProgress: .constant(0.5)
    )
}
