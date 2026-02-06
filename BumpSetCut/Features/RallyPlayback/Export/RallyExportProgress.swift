import SwiftUI
import AVFoundation

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

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                progressIndicator

                statusText

                if exportStatus == .completed {
                    successView
                }

                Spacer()

                if exportStatus != .completed {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.red)
                }
            }
            .padding(24)
            .navigationTitle(exportType.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            startExport()
        }
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
                Text("\(exportedCount) of \(savedRallies.count) rallies")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Text("Export completed successfully!")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            Button("Done") {
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func startExport() {
        Task {
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

        do {
            await MainActor.run {
                exportStatus = .exporting
            }

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            let videoDuration = try await CMTimeGetSeconds(asset.load(.duration))
            let exporter = VideoExporter()
            let rawSegments = savedRallies.compactMap { index in
                index < metadata.rallySegments.count ? (index, metadata.rallySegments[index]) : nil
            }

            // Apply per-rally trim adjustments
            let selectedSegments = rawSegments.map { (rallyIndex, segment) -> RallySegment in
                guard let adj = trimAdjustments[rallyIndex] else { return segment }
                return segment.withAdjustedTimes(
                    startSeconds: max(0, segment.startTime - adj.before),
                    endSeconds: min(videoDuration, segment.endTime + adj.after)
                )
            }

            if exportType == .individual {
                // Export individual videos
                for (index, segment) in selectedSegments.enumerated() {
                    let progress = Double(index) / Double(selectedSegments.count)
                    await MainActor.run {
                        exportProgress = progress
                        exportedCount = index
                    }

                    try await exporter.exportRallyToPhotoLibrary(asset: asset, rally: segment, index: index)
                }
            } else {
                // Export stitched video
                try await exporter.exportStitchedRalliesToPhotoLibrary(asset: asset, rallies: selectedSegments)
            }

            await MainActor.run {
                exportProgress = 1.0
                exportStatus = .completed
                isExporting = false
            }

        } catch {
            await MainActor.run {
                exportStatus = .failed(error.localizedDescription)
                isExporting = false
            }
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
