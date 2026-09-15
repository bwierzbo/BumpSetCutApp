//
//  GameScoringView.swift
//  BumpSetCut
//
//  Game Viewer, phase 1: step through detected rallies, tap the team that
//  won each point, mark set breaks, then export the full stitched game with
//  the running scoreboard burned in. Phase 2 pre-fills winners from
//  serve-side detection; this stays as the correction layer.
//

import SwiftUI
import AVFoundation

struct GameScoringView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: GameScoringViewModel
    @State private var showExportSheet = false

    init(videoMetadata: VideoMetadata) {
        _viewModel = State(initialValue: GameScoringViewModel(videoMetadata: videoMetadata))
    }

    private var teamAColor: Color { Color(hex: viewModel.scoring.teamA.colorHex) }
    private var teamBColor: Color { Color(hex: viewModel.scoring.teamB.colorHex) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                if viewModel.loadFailed {
                    BSCEmptyState(
                        icon: "sportscourt",
                        title: "Nothing to Score",
                        message: "Process this video first so its rallies can be scored."
                    )
                } else if !viewModel.isLoaded {
                    ProgressView()
                } else {
                    VStack(spacing: BSCSpacing.md) {
                        scoreboard
                        videoPane
                        rallyStepper
                        assignmentControls
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.lg)
                }
            }
            .navigationTitle("Score Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.bscTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.player.pause()
                        showExportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.isLoaded)
                    .accessibilityLabel("Export scored game")
                    .accessibilityIdentifier(AccessibilityID.GameScoring.export)
                }
            }
        }
        .task { await viewModel.load() }
        .onDisappear { viewModel.cleanup() }
        .sheet(isPresented: Binding(
            get: { viewModel.needsSetup && viewModel.isLoaded },
            set: { if !$0 { viewModel.needsSetup = false } }
        )) {
            GameTeamSetupSheet(
                teamA: viewModel.scoring.teamA,
                teamB: viewModel.scoring.teamB
            ) { teamA, teamB in
                viewModel.saveTeams(teamA: teamA, teamB: teamB)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showExportSheet) {
            GameExportSheet(
                gameName: viewModel.videoMetadata.displayName,
                clips: viewModel.exportClips(),
                overlays: exportOverlays()
            )
        }
    }

    // MARK: - Scoreboard

    private var scoreboard: some View {
        HStack(spacing: BSCSpacing.md) {
            teamScoreChip(
                team: viewModel.scoring.teamA,
                color: teamAColor,
                score: viewModel.currentState.scoreA
            )

            VStack(spacing: BSCSpacing.xxs) {
                Text("–")
                    .bscFont(size: 22, weight: .bold)
                    .foregroundColor(.bscTextSecondary)
                if viewModel.showsSets {
                    Text("Sets \(viewModel.currentState.setsA)–\(viewModel.currentState.setsB)")
                        .bscFont(size: 11, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            teamScoreChip(
                team: viewModel.scoring.teamB,
                color: teamBColor,
                score: viewModel.currentState.scoreB
            )
        }
        .accessibilityIdentifier(AccessibilityID.GameScoring.scoreboard)
    }

    private func teamScoreChip(team: GameTeam, color: Color, score: Int) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text(team.name)
                .bscFont(size: 15, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(1)
            Text("\(score)")
                .bscFont(size: 24, weight: .bold, design: .monospaced)
                .foregroundColor(.bscTextPrimary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Video

    private var videoPane: some View {
        ZStack {
            Color.bscMediaBackground

            CustomVideoPlayerView(
                player: viewModel.player,
                gravity: .resizeAspect,
                onReadyForDisplay: { _ in }
            )

            if !viewModel.isPlaying {
                Image(systemName: "play.fill")
                    .bscFont(size: 44)
                    .foregroundColor(.bscOnMediaSecondary)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { viewModel.togglePlayback() }
    }

    // MARK: - Rally Stepper

    private var rallyStepper: some View {
        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton(icon: "chevron.left", style: .ghost, size: .compact, accessibilityLabel: "Previous rally") {
                viewModel.goPrevious()
            }
            .disabled(viewModel.currentIndex == 0)
            .opacity(viewModel.currentIndex == 0 ? 0.35 : 1)

            VStack(spacing: BSCSpacing.xxs) {
                Text("Rally \(viewModel.currentIndex + 1) of \(viewModel.rallyCount)")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                Text("\(viewModel.scoredCount) scored")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AccessibilityID.GameScoring.rallyCounter)

            BSCIconButton(icon: "chevron.right", style: .ghost, size: .compact, accessibilityLabel: "Next rally") {
                viewModel.goNext()
            }
            .disabled(viewModel.currentIndex >= viewModel.rallyCount - 1)
            .opacity(viewModel.currentIndex >= viewModel.rallyCount - 1 ? 0.35 : 1)
        }
    }

    // MARK: - Assignment

    private var assignmentControls: some View {
        VStack(spacing: BSCSpacing.sm) {
            HStack(spacing: BSCSpacing.md) {
                pointButton(team: viewModel.scoring.teamA, color: teamAColor, winner: .teamA,
                            id: AccessibilityID.GameScoring.pointTeamA)
                pointButton(team: viewModel.scoring.teamB, color: teamBColor, winner: .teamB,
                            id: AccessibilityID.GameScoring.pointTeamB)
            }

            HStack(spacing: BSCSpacing.lg) {
                Button {
                    viewModel.clearCurrentPoint()
                } label: {
                    Label("No Point", systemImage: "slash.circle")
                        .bscFont(size: 13, weight: .medium)
                        .foregroundColor(viewModel.currentWinner == nil ? .bscTextTertiary : .bscTextSecondary)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .disabled(viewModel.currentWinner == nil)

                Button {
                    viewModel.toggleSetBreak()
                } label: {
                    Label(
                        viewModel.currentStartsNewSet ? "Starts New Set ✓" : "Starts New Set",
                        systemImage: "flag.checkered"
                    )
                    .bscFont(size: 13, weight: .medium)
                    .foregroundColor(viewModel.currentStartsNewSet ? .bscPrimaryText : .bscTextSecondary)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
                }
                .disabled(viewModel.currentIndex == 0)
                .accessibilityIdentifier(AccessibilityID.GameScoring.setBreak)
            }
        }
    }

    private func pointButton(team: GameTeam, color: Color, winner: GamePointWinner, id: String) -> some View {
        let isSelected = viewModel.currentWinner == winner
        return Button {
            viewModel.assign(winner)
        } label: {
            VStack(spacing: BSCSpacing.xxs) {
                Text("+1")
                    .bscFont(size: 20, weight: .bold)
                Text(team.name)
                    .bscFont(size: 13, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(color.opacity(isSelected ? 1.0 : 0.75))
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 16)
                        .foregroundColor(.white)
                        .padding(BSCSpacing.xs)
                }
            }
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel("Point for \(team.name)")
    }

    // MARK: - Export Overlays

    private func exportOverlays() -> [VideoExporter.GameScoreOverlay?] {
        let states = viewModel.states
        let showsSets = viewModel.showsSets
        let scoring = viewModel.scoring
        return states.map { state in
            VideoExporter.GameScoreOverlay(
                teamAName: scoring.teamA.name,
                teamBName: scoring.teamB.name,
                teamAColor: UIColor(Color(hex: scoring.teamA.colorHex)),
                teamBColor: UIColor(Color(hex: scoring.teamB.colorHex)),
                state: state,
                showsSets: showsSets
            )
        }
    }
}

// MARK: - Team Setup Sheet

struct GameTeamSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var teamAName: String
    @State private var teamBName: String
    @State private var teamAColor: String
    @State private var teamBColor: String
    let onSave: (GameTeam, GameTeam) -> Void

    private static let palette = [
        "#F97316", "#3B82F6", "#EF4444", "#22C55E",
        "#A855F7", "#EAB308", "#14B8A6", "#EC4899"
    ]

    init(teamA: GameTeam, teamB: GameTeam, onSave: @escaping (GameTeam, GameTeam) -> Void) {
        _teamAName = State(initialValue: teamA.name)
        _teamBName = State(initialValue: teamB.name)
        _teamAColor = State(initialValue: teamA.colorHex)
        _teamBColor = State(initialValue: teamB.colorHex)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: BSCSpacing.xl) {
                    teamEditor(title: "Team 1", name: $teamAName, colorHex: $teamAColor,
                               nameID: AccessibilityID.GameScoring.teamAField)
                    teamEditor(title: "Team 2", name: $teamBName, colorHex: $teamBColor,
                               nameID: AccessibilityID.GameScoring.teamBField)
                    Spacer()
                }
                .padding(BSCSpacing.xl)
            }
            .navigationTitle("Teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Start Scoring") {
                        onSave(
                            GameTeam(name: cleanName(teamAName, fallback: "Home"), colorHex: teamAColor),
                            GameTeam(name: cleanName(teamBName, fallback: "Away"), colorHex: teamBColor)
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscPrimaryText)
                    .accessibilityIdentifier(AccessibilityID.GameScoring.startScoring)
                }
            }
        }
    }

    private func cleanName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(14))
    }

    private func teamEditor(title: String, name: Binding<String>, colorHex: Binding<String>, nameID: String) -> some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            Text(title)
                .bscFont(size: 14, weight: .semibold)
                .foregroundColor(.bscTextSecondary)
                .textCase(.uppercase)

            TextField("Team name", text: name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(nameID)

            HStack(spacing: BSCSpacing.sm) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        colorHex.wrappedValue = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().stroke(
                                    colorHex.wrappedValue == hex ? Color.bscTextPrimary : .clear,
                                    lineWidth: 2.5
                                )
                            )
                    }
                    .accessibilityLabel("Team color")
                    .accessibilityAddTraits(colorHex.wrappedValue == hex ? .isSelected : [])
                }
            }
        }
    }
}
