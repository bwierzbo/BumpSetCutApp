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

    /// Scoreboard size choices offered before export, mapped to the exporter's scale.
    enum ScoreboardSize: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: return 0.75
            case .medium: return 1.0
            case .large: return 1.35
            }
        }

        var label: String { rawValue.capitalized }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isConfiguring = true
    @State private var exportStatus: RallyExportStatus = .preparing
    @State private var exportProgress: Double = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var storageError: String?
    @State private var exportedURL: URL?
    @State private var showShareSheet = false

    // Remembered across exports — most people want the scoreboard in the same spot every game.
    @AppStorage("gameExport.scoreboardPosition") private var scoreboardPositionRaw = VideoExporter.ScoreboardPosition.topLeft.rawValue
    @AppStorage("gameExport.scoreboardSize") private var scoreboardSizeRaw = ScoreboardSize.medium.rawValue

    private var scoreboardPosition: VideoExporter.ScoreboardPosition {
        VideoExporter.ScoreboardPosition(rawValue: scoreboardPositionRaw) ?? .topLeft
    }

    private var scoreboardSize: ScoreboardSize {
        ScoreboardSize(rawValue: scoreboardSizeRaw) ?? .medium
    }

    var body: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xxl) {
                if isConfiguring {
                    configureView
                } else {
                    Spacer()
                    exportPhaseView
                }
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("Export Scored Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isConfiguring {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.bscTextSecondary)
                    }
                }
            }
        }
        .onDisappear {
            exportTask?.cancel()
            cleanupExportedFile()
        }
        .interactiveDismissDisabled(!isConfiguring && (exportStatus == .exporting || exportStatus == .preparing))
    }

    @ViewBuilder
    private var exportPhaseView: some View {
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

    // MARK: - Configure

    private var configureView: some View {
        VStack(spacing: BSCSpacing.xxl) {
            scoreboardPreview

            VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                Text("Scoreboard Position")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                positionGrid
            }

            VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                Text("Scoreboard Size")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                Picker("Scoreboard Size", selection: $scoreboardSizeRaw) {
                    ForEach(ScoreboardSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.GameScoring.scoreboardSize)
            }

            Spacer()

            Button {
                isConfiguring = false
                startExport()
            } label: {
                Label("Export to Photos", systemImage: "square.and.arrow.up")
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscOnPrimary)
                    .padding(.vertical, BSCSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient.bscPrimaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
            }
            .accessibilityIdentifier(AccessibilityID.GameScoring.confirmExport)
        }
        .padding(.top, BSCSpacing.md)
    }

    /// Live preview: a stand-in video frame with the scoreboard pill in the
    /// chosen corner at the chosen size, using the real team names/colors.
    private var scoreboardPreview: some View {
        ZStack(alignment: previewAlignment) {
            RoundedRectangle(cornerRadius: BSCRadius.md)
                .fill(Color.black.opacity(0.85))
            miniScoreboard
                .padding(BSCSpacing.sm)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .animation(.bscSpring, value: scoreboardPositionRaw)
        .animation(.bscSpring, value: scoreboardSizeRaw)
    }

    private var previewAlignment: Alignment {
        switch scoreboardPosition {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private var previewOverlay: VideoExporter.GameScoreOverlay? {
        overlays.compactMap { $0 }.first
    }

    private var miniScoreboard: some View {
        let base: CGFloat = 11 * scoreboardSize.scale
        return HStack(spacing: base * 0.35) {
            Circle()
                .fill(Color(previewOverlay?.teamAColor ?? .systemOrange))
                .frame(width: base * 0.7, height: base * 0.7)
            Text("\(previewOverlay?.teamAName ?? "Team A") 0")
                .font(.system(size: base, weight: .bold))
            Text("–")
                .font(.system(size: base))
                .opacity(0.6)
            Text("0 \(previewOverlay?.teamBName ?? "Team B")")
                .font(.system(size: base, weight: .bold))
            Circle()
                .fill(Color(previewOverlay?.teamBColor ?? .systemTeal))
                .frame(width: base * 0.7, height: base * 0.7)
        }
        .foregroundColor(.white)
        .lineLimit(1)
        .padding(.horizontal, base * 0.8)
        .padding(.vertical, base * 0.5)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    private var positionGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: BSCSpacing.sm),
            GridItem(.flexible(), spacing: BSCSpacing.sm)
        ]
        return LazyVGrid(columns: columns, spacing: BSCSpacing.sm) {
            positionButton(.topLeft, label: "Top Left", icon: "arrow.up.left")
            positionButton(.topRight, label: "Top Right", icon: "arrow.up.right")
            positionButton(.bottomLeft, label: "Bottom Left", icon: "arrow.down.left")
            positionButton(.bottomRight, label: "Bottom Right", icon: "arrow.down.right")
        }
    }

    private func positionButton(_ position: VideoExporter.ScoreboardPosition, label: String, icon: String) -> some View {
        let isSelected = scoreboardPosition == position
        return Button {
            scoreboardPositionRaw = position.rawValue
        } label: {
            Label(label, systemImage: icon)
                .bscFont(size: 15, weight: isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .bscOnPrimary : .bscTextPrimary)
                .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.md)
                        .fill(isSelected
                              ? AnyShapeStyle(LinearGradient.bscPrimaryGradient)
                              : AnyShapeStyle(Color.bscSurfaceGlass))
                )
        }
        .accessibilityIdentifier(AccessibilityID.GameScoring.scoreboardPositionPrefix + position.rawValue)
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
                scoreboardPosition: scoreboardPosition,
                scoreboardScale: scoreboardSize.scale,
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
