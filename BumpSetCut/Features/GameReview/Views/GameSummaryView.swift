//
//  GameSummaryView.swift
//  BumpSetCut
//
//  Final score summary after completing a Game Review.
//

import SwiftUI

struct GameSummaryView: View {
    let score: GameScore
    let decisions: [RallyScoringDecision]
    let isExporting: Bool
    let exportProgress: Double
    let exportedURL: URL?
    let exportError: String?
    @Binding var showShareSheet: Bool
    let onExport: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BSCSpacing.xl) {
                    // Final Score
                    finalScoreCard

                    // Rally Breakdown
                    if !decisions.isEmpty {
                        rallyBreakdown
                    }

                    // Export Section
                    exportSection
                }
                .padding(BSCSpacing.lg)
            }
            .navigationTitle("Game Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedURL {
                    ActivityViewController(activityItems: [url])
                }
            }
        }
    }

    // MARK: - Export Section

    @ViewBuilder
    private var exportSection: some View {
        if isExporting {
            VStack(spacing: BSCSpacing.sm) {
                ProgressView(value: exportProgress) {
                    Text("Exporting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(exportProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(BSCSpacing.md)
        } else if exportedURL != nil {
            VStack(spacing: BSCSpacing.sm) {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.bscSuccess)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bscPrimary)
            }
        } else if let error = exportError {
            VStack(spacing: BSCSpacing.sm) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.bscWarning)

                Button(action: onExport) {
                    Label("Retry Export", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BSCSpacing.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bscPrimary)
            }
        } else {
            Button(action: onExport) {
                Label("Export Game Video", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BSCSpacing.md)
            }
            .buttonStyle(.borderedProminent)
            .tint(.bscPrimary)
        }
    }

    // MARK: - Final Score Card

    private var finalScoreCard: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text("Final Score")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: BSCSpacing.xl) {
                VStack {
                    Text("Near")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(score.near)")
                        .font(.system(size: 48, weight: .bold))
                        .monospacedDigit()
                }

                Text("—")
                    .font(.title)
                    .foregroundStyle(.secondary)

                VStack {
                    Text("Far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(score.far)")
                        .font(.system(size: 48, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .padding(BSCSpacing.xl)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: BSCRadius.lg))
    }

    // MARK: - Rally Breakdown

    private var rallyBreakdown: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            Text("Rally Breakdown")
                .font(.headline)

            LazyVStack(spacing: BSCSpacing.xs) {
                ForEach(Array(0..<decisions.count), id: \.self) { index in
                    let decision = decisions[index]
                    HStack {
                        Text("Rally \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)

                        Image(systemName: "sportscourt.fill")
                            .font(.caption2)
                            .foregroundColor(.bscOrange)

                        Text(decision.server.displayName)
                            .font(.caption)
                            .frame(width: 36)

                        Spacer()

                        Image(systemName: decision.pointWinner == .near ? "arrow.left" : "arrow.right")
                            .font(.caption)
                            .foregroundColor(decision.pointWinner == .near ? .bscPrimary : .bscSuccess)

                        Text("\(decision.scoreAfter.near) – \(decision.scoreAfter.far)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)

                        if decision.isManuallyOverridden {
                            Image(systemName: "pencil.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.bscWarning)
                        }
                    }
                    .padding(.vertical, BSCSpacing.xxs)
                }
            }
        }
    }
}
