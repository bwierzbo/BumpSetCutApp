//
//  GameSetupView.swift
//  BumpSetCut
//
//  Setup screen for Game Review mode — configure scoring, first server, etc.
//

import SwiftUI

struct GameSetupView: View {
    let videoId: UUID
    let onStart: (GameSetup) -> Void
    let onResume: (GameReviewState) -> Void

    @State private var viewModel: GameSetupViewModel
    @Environment(\.dismiss) private var dismiss

    init(videoId: UUID, onStart: @escaping (GameSetup) -> Void, onResume: @escaping (GameReviewState) -> Void) {
        self.videoId = videoId
        self.onStart = onStart
        self.onResume = onResume
        self._viewModel = State(wrappedValue: GameSetupViewModel(videoId: videoId))
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.hasExistingReview, let state = viewModel.existingReviewState {
                    resumeSection(state: state)
                }

                scoringModeSection
                switchSection
            }
            .navigationTitle("Game Review Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Review") {
                        onStart(viewModel.buildSetup())
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                viewModel.loadExistingState()
            }
        }
    }

    // MARK: - Resume Section

    private func resumeSection(state: GameReviewState) -> some View {
        Section {
            Button {
                onResume(state)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                        Text("Resume Previous Review")
                            .font(.headline)
                        Text("Rally \(state.currentRallyIndex + 1) • \(state.decisions.count) points scored")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.bscPrimary)
                }
            }
        } header: {
            Text("Continue")
        }
    }

    // MARK: - Scoring Mode

    private var scoringModeSection: some View {
        Section {
            Picker("Scoring", selection: $viewModel.scoringMode) {
                ForEach(ScoringMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Scoring Mode")
        } footer: {
            Text(viewModel.scoringMode == .rallyScoring
                 ? "Either team can score on any rally."
                 : "Only the serving team can score. Receiving team wins cause a sideout.")
        }
    }

    // MARK: - Switch Sides

    private var switchSection: some View {
        Section {
            Toggle("Switch Sides", isOn: $viewModel.switchEnabled)

            if viewModel.switchEnabled {
                Stepper("Every \(viewModel.switchInterval) points", value: $viewModel.switchInterval, in: 1...25)
            }
        } header: {
            Text("Side Switching")
        }
    }
}
