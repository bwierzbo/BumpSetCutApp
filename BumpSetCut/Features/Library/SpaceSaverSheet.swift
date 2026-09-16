//
//  SpaceSaverSheet.swift
//  BumpSetCut
//
//  "Free Up Space" for a processed video: shows what trimming to
//  rallies-only would save, confirms the (irreversible) removal of the
//  footage between rallies, then runs the trim with progress.
//

import AVFoundation
import SwiftUI
import UIKit

struct SpaceSaverSheet: View {
    let video: VideoMetadata
    let mediaStore: MediaStore
    let metadataStore: MetadataStore

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case estimating
        case ready(savedText: String, minutesText: String)
        case notWorthIt
        case trimming
        case done(savedText: String)
        case failed(String)
    }

    @State private var phase: Phase = .estimating
    @State private var estimate: RallySpaceSaver.Estimate?
    @State private var progress: Double = 0
    @State private var trimTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xxl) {
                Spacer()

                switch phase {
                case .estimating:
                    ProgressView()
                    Text("Measuring dead time…")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)

                case .ready(let savedText, let minutesText):
                    Image(systemName: "internaldrive")
                        .bscFont(size: 52)
                        .foregroundColor(.bscPrimary)
                    VStack(spacing: BSCSpacing.sm) {
                        Text("Keep just the rallies")
                            .bscFont(size: 20, weight: .bold)
                            .foregroundColor(.bscTextPrimary)
                        Text("Removes \(minutesText) of footage between rallies and frees about \(savedText). Your rallies, trims, favorites and scoring are kept — the removed footage can't be recovered.")
                            .bscFont(size: 15)
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(spacing: BSCSpacing.md) {
                        Button {
                            startTrim()
                        } label: {
                            Text("Free Up \(savedText)")
                                .bscFont(size: 17, weight: .semibold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                        }
                        .accessibilityIdentifier(AccessibilityID.SpaceSaver.confirm)

                        Button {
                            dismiss()
                        } label: {
                            Text("Keep Full Video")
                                .bscFont(size: 15, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
                    }

                case .notWorthIt:
                    Image(systemName: "checkmark.seal")
                        .bscFont(size: 52)
                        .foregroundColor(.bscSuccessText)
                    VStack(spacing: BSCSpacing.sm) {
                        Text("Already lean")
                            .bscFont(size: 20, weight: .bold)
                            .foregroundColor(.bscTextPrimary)
                        Text("This video is mostly rallies — trimming wouldn't free meaningful space.")
                            .bscFont(size: 15)
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .bscFont(size: 17, weight: .semibold)
                            .foregroundColor(.bscTextSecondary)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }

                case .trimming:
                    ZStack {
                        Circle()
                            .fill(Color.bscSurfaceGlass)
                            .frame(width: 148, height: 148)
                        BSCExportProgressRing(progress: progress)
                    }
                    Text("Trimming to rallies…")
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                    Text("Keep the app open — this replaces the video file.")
                        .bscFont(size: 13)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()

                case .done(let savedText):
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 60)
                        .foregroundColor(.bscSuccessText)
                    Text("Freed \(savedText)")
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                    Text("The video now contains just your rallies.")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .bscFont(size: 17, weight: .semibold)
                            .foregroundColor(.bscOnPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, BSCSpacing.md)
                            .background(LinearGradient.bscPrimaryGradient)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    }
                    .accessibilityIdentifier(AccessibilityID.Export.doneButton)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .bscFont(size: 60)
                        .foregroundColor(.bscError)
                    Text("Couldn't free space")
                        .bscFont(size: 20, weight: .bold)
                        .foregroundColor(.bscTextPrimary)
                    Text(message)
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
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
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("Free Up Space")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await loadEstimate() }
        .onDisappear { trimTask?.cancel() }
        .interactiveDismissDisabled(phase == .trimming)
    }

    private func loadEstimate() async {
        guard let estimate = await RallySpaceSaver.estimate(for: video, metadataStore: metadataStore) else {
            phase = .notWorthIt
            return
        }
        self.estimate = estimate
        phase = .ready(
            savedText: ByteCountFormatter.string(fromByteCount: estimate.savedBytes, countStyle: .file),
            minutesText: formatMinutes(estimate.savedSeconds)
        )
    }

    private func startTrim() {
        guard let estimate else { return }
        phase = .trimming
        trimTask = Task {
            do {
                let freed = try await RallySpaceSaver.trim(
                    video: video,
                    estimate: estimate,
                    mediaStore: mediaStore,
                    metadataStore: metadataStore
                ) { fraction in
                    Task { @MainActor in
                        progress = fraction
                    }
                }
                await MainActor.run {
                    UINotificationFeedbackGenerator.success()
                    phase = .done(savedText: ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))
                }
            } catch {
                await MainActor.run {
                    UINotificationFeedbackGenerator.error()
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func formatMinutes(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins) minutes"
        }
        return "\(secs) seconds"
    }
}
