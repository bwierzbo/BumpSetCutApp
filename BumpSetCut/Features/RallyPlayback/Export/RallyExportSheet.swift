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
            VStack(spacing: 24) {
                if savedRallies.isEmpty {
                    noSavedRalliesView
                } else {
                    exportOptionsView
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Export Rallies")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
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
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            .padding(.vertical, 32)
    }

    private var rallyCountLabel: String {
        let count = savedRallies.count
        return count == 1 ? "1 Rally" : "\(count) Rallies"
    }

    private var exportOptionsView: some View {
        VStack(spacing: 20) {
            Text("Export \(rallyCountLabel)")
                .font(.headline)
                .padding(.bottom, 8)

            // Individual Export Option
            RallyExportOptionCard(
                title: "Export Individual Videos",
                subtitle: "Save each rally as a separate video",
                icon: "square.stack.3d.up",
                color: .blue,
                isDisabled: isExporting
            ) {
                guard !isExporting else { return }
                exportType = .individual
            }

            // Stitched Export Option
            RallyExportOptionCard(
                title: "Export Combined Video",
                subtitle: "Stitch all saved rallies into one video",
                icon: "film.stack",
                color: .purple,
                isDisabled: isExporting
            ) {
                guard !isExporting else { return }
                exportType = .stitched
            }
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
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isDisabled ? .secondary : color)
                    .frame(width: 50, height: 50)
                    .background((isDisabled ? Color.secondary : color).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(isDisabled ? .secondary : .primary)

                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(UIColor.separator), lineWidth: 1)
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
