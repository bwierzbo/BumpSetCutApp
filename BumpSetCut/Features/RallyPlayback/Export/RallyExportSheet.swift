import SwiftUI

// MARK: - Rally Export Sheet

struct RallyExportSheet: View {
    let savedRallies: [Int]
    let totalRallies: Int
    let processingMetadata: ProcessingMetadata?
    let videoMetadata: VideoMetadata
    let trimAdjustments: [Int: RallyTrimAdjustment]
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exportType: RallyExportType?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0

    var body: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xl) {
                if savedRallies.isEmpty {
                    noSavedRalliesView
                } else {
                    exportOptionsView
                }

                Spacer()
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("Export Rallies")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
                    .foregroundColor(.bscPrimary)
                    .disabled(isExporting)
                }
            }
        }
        .sheet(item: $exportType) { type in
            RallyExportProgress(
                exportType: type,
                savedRallies: savedRallies,
                processingMetadata: processingMetadata,
                videoMetadata: videoMetadata,
                trimAdjustments: trimAdjustments,
                isExporting: $isExporting,
                exportProgress: $exportProgress
            )
        }
    }

    private var noSavedRalliesView: some View {
        Text("No rallies saved — swipe right on rallies to keep them.")
            .font(.body)
            .foregroundColor(.bscTextSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            .padding(.vertical, BSCSpacing.xxl)
    }

    private var rallyCountLabel: String {
        let count = savedRallies.count
        return count == 1 ? "1 Rally" : "\(count) Rallies"
    }

    private var exportOptionsView: some View {
        VStack(spacing: BSCSpacing.lg) {
            Text("Export \(rallyCountLabel)")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)
                .padding(.bottom, BSCSpacing.sm)

            // Individual Export Option
            RallyExportOptionCard(
                title: "Export Individual Videos",
                subtitle: "Save each rally as a separate video",
                icon: "square.stack.3d.up",
                color: .bscPrimary,
                isDisabled: isExporting
            ) {
                guard !isExporting else { return }
                exportType = .individual
            }
            .accessibilityIdentifier(AccessibilityID.Export.individualOption)
            .accessibilityLabel("Export individual videos")
            .accessibilityHint("Save each rally as a separate video file")

            // Stitched Export Option
            RallyExportOptionCard(
                title: "Export Combined Video",
                subtitle: "Stitch all saved rallies into one video",
                icon: "film.stack",
                color: .bscTeal,
                isDisabled: isExporting
            ) {
                guard !isExporting else { return }
                exportType = .stitched
            }
            .accessibilityIdentifier(AccessibilityID.Export.combinedOption)
            .accessibilityLabel("Export combined video")
            .accessibilityHint("Stitch all saved rallies into one video file")
        }
    }
}

// MARK: - Export Option Card

struct RallyExportOptionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BSCSpacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isDisabled ? .bscTextTertiary : color)
                    .frame(width: 50, height: 50)
                    .background((isDisabled ? Color.bscTextTertiary : color).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(isDisabled ? .bscTextTertiary : .bscTextPrimary)

                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(.bscTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.bscTextTertiary)
            }
            .padding(BSCSpacing.lg)
            .background(Color.bscBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    RallyExportSheet(
        savedRallies: [0, 2, 4],
        totalRallies: 5,
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
        onDismiss: {}
    )
}
