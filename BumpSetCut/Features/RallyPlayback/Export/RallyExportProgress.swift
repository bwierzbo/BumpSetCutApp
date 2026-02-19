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
            VStack(spacing: 32) {
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
                        .foregroundColor(.red)

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
            .padding(24)
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
        VStack(spacing: 16) {
            if exportStatus == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
            } else {
                ProgressView(value: exportProgress)
                    .progressViewStyle(CircularProgressViewStyle(tint: exportType == .individual ? .blue : .purple))
                    .scaleEffect(2.0)
            }
        }
    }

    private var statusText: some View {
        VStack(spacing: 8) {
            Text(exportStatus.message)
                .font(.headline)
                .multilineTextAlignment(.center)

            if exportStatus == .exporting {
                if exportType == .individual {
                    Text("\(exportedCount) of \(savedRallies.count) rallies")
                        .font(.body)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(Int(exportProgress * 100))%")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Text("Saved to Photos")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            if !exportedURLs.isEmpty {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.bscOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Button("Done") {
                cleanupExportedFiles()
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.secondary)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: exportedURLs)
        }
    }

    private func storageErrorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Not Enough Storage")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Dismiss") {
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.red)
        }
    }

    private func failedView(errorMessage: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            VStack(spacing: 8) {
                Text("Export Failed")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button("Retry") {
                    storageError = nil
                    startExport()
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Dismiss") {
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.red)
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
                exportStatus = .failed(error.localizedDescription)
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
