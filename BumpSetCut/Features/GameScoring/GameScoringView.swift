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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var viewModel: GameScoringViewModel
    @State private var showExportSheet = false
    @State private var showTimelineEditor = false

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
                } else if verticalSizeClass == .compact {
                    // Landscape: video gets the height; score and controls
                    // sit in a column beside it.
                    HStack(spacing: BSCSpacing.lg) {
                        videoPane
                        VStack(spacing: BSCSpacing.sm) {
                            scoreboard
                            rallyStepper
                            Spacer(minLength: 0)
                            assignmentControls
                        }
                        .frame(maxWidth: BSCContentWidth.compact + BSCSpacing.huge)
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.sm)
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Fix a wrong/missed rally without leaving the scoring
                    // flow: opens the timeline editor at the current spot.
                    Button {
                        viewModel.player.pause()
                        viewModel.isPlaying = false
                        showTimelineEditor = true
                    } label: {
                        Image(systemName: "timeline.selection")
                    }
                    .disabled(!viewModel.isLoaded)
                    .accessibilityLabel("Fix rallies on the timeline")
                    .accessibilityIdentifier(AccessibilityID.GameScoring.editTimeline)

                    Button {
                        viewModel.player.pause()
                        viewModel.isPlaying = false
                        showExportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.isLoaded)
                    .accessibilityLabel("Export scored game")
                    .accessibilityIdentifier(AccessibilityID.GameScoring.export)

                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(.bscPrimaryText)
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
                teamB: viewModel.scoring.teamB,
                onSave: { teamA, teamB in
                    viewModel.saveTeams(teamA: teamA, teamB: teamB)
                },
                // Teams gate scoring, so backing out of setup leaves the viewer.
                onCancel: {
                    viewModel.needsSetup = false
                    dismiss()
                }
            )
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showExportSheet) {
            GameExportSheet(
                gameName: viewModel.videoMetadata.displayName,
                clips: viewModel.exportClips(),
                overlays: exportOverlays()
            )
        }
        .fullScreenCover(isPresented: $showTimelineEditor) {
            RallyTimelineView(
                videoURL: viewModel.videoMetadata.originalURL,
                videoId: viewModel.videoMetadata.originalVideoId ?? viewModel.videoMetadata.id,
                metadataStore: viewModel.metadataStore,
                // Open where the scorer was looking — the missed serve is
                // usually in the dead time right around the current rally.
                initialTime: viewModel.effectiveStart(for: viewModel.currentIndex),
                onSaved: {
                    Task { await viewModel.reloadAfterTimelineEdit() }
                }
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

            Text(verbatim: "–")
                .bscFont(size: 22, weight: .bold)
                .foregroundColor(.bscTextSecondary)

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
            Text(verbatim: score.formatted())
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
        .accessibilityElement()
        .accessibilityLabel("Rally \(viewModel.currentIndex + 1) video")
        .accessibilityValue(viewModel.isPlaying ? "Playing" : "Paused")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays or pauses the rally")
        .accessibilityAction { viewModel.togglePlayback() }
    }

    // MARK: - Rally Stepper

    private var rallyStepper: some View {
        HStack(spacing: BSCSpacing.lg) {
            BSCIconButton(icon: "chevron.backward", style: .ghost, size: .compact, accessibilityLabel: "Previous rally") {
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

            BSCIconButton(icon: "chevron.forward", style: .ghost, size: .compact, accessibilityLabel: "Next rally") {
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

            // A recording is one set — no set controls, just point correction.
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
        }
    }

    private func pointButton(team: GameTeam, color: Color, winner: GamePointWinner, id: String) -> some View {
        let isSelected = viewModel.currentWinner == winner
        // Black or white, whichever reads on this team's color (white on
        // yellow was 1.9:1). The fill stays solid so the pick holds.
        let labelColor = GameTeamPalette.labelColor(onHex: team.colorHex)
        return Button {
            viewModel.assign(winner)
        } label: {
            VStack(spacing: BSCSpacing.xxs) {
                Text(verbatim: 1.formatted(.number.sign(strategy: .always())))
                    .bscFont(size: 20, weight: .bold)
                Text(team.name)
                    .bscFont(size: 13, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundColor(labelColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(Color.bscTextPrimary, lineWidth: isSelected ? 3 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 16)
                        .foregroundColor(labelColor)
                        .padding(BSCSpacing.xs)
                }
            }
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel(Text("Point for \(team.name)"))
        .accessibilityValue(isSelected ? Text("\(team.name) has this point") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Export Overlays

    private func exportOverlays() -> [VideoExporter.GameScoreOverlay?] {
        let states = viewModel.states
        let scoring = viewModel.scoring
        return states.map { state in
            VideoExporter.GameScoreOverlay(
                teamAName: scoring.teamA.name,
                teamBName: scoring.teamB.name,
                teamAColor: UIColor(Color(hex: scoring.teamA.colorHex)),
                teamBColor: UIColor(Color(hex: scoring.teamB.colorHex)),
                state: state,
                showsSets: false  // one recording = one set
            )
        }
    }
}

// MARK: - Team Palette

/// Team colors offered in setup. Teams store only the hex, so swatches carry
/// a name for VoiceOver.
enum GameTeamPalette {
    struct Swatch: Identifiable {
        let name: LocalizedStringResource
        let hex: String
        var id: String { hex }
    }

    static let orange = Swatch(name: "Orange", hex: "#F97316")
    static let blue = Swatch(name: "Blue", hex: "#3B82F6")
    static let red = Swatch(name: "Red", hex: "#EF4444")
    static let green = Swatch(name: "Green", hex: "#22C55E")
    static let purple = Swatch(name: "Purple", hex: "#A855F7")
    static let yellow = Swatch(name: "Yellow", hex: "#EAB308")
    static let teal = Swatch(name: "Teal", hex: "#14B8A6")
    static let pink = Swatch(name: "Pink", hex: "#EC4899")

    static let swatches = [orange, blue, red, green, purple, yellow, teal, pink]

    /// Black or white text, whichever has the higher WCAG contrast on `hex`.
    static func labelColor(onHex hex: String) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Color(hex: hex)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        let contrastWithBlack = (luminance + 0.05) / 0.05
        return contrastWithBlack > contrastWithWhite ? .black : .white
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
    let onCancel: () -> Void

    init(teamA: GameTeam, teamB: GameTeam,
         onSave: @escaping (GameTeam, GameTeam) -> Void,
         onCancel: @escaping () -> Void) {
        _teamAName = State(initialValue: teamA.name)
        _teamBName = State(initialValue: teamB.name)
        _teamAColor = State(initialValue: teamA.colorHex)
        _teamBColor = State(initialValue: teamB.colorHex)
        self.onSave = onSave
        self.onCancel = onCancel
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.bscTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Scoring") {
                        onSave(
                            GameTeam(name: cleanName(teamAName, fallback: String(localized: "gameScoring.defaultTeamA", defaultValue: "Home", comment: "Default name of the first team when scoring a game (the home team)")), colorHex: teamAColor),
                            GameTeam(name: cleanName(teamBName, fallback: String(localized: "gameScoring.defaultTeamB", defaultValue: "Away", comment: "Default name of the second team when scoring a game (the away team)")), colorHex: teamBColor)
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

    private func teamEditor(title: LocalizedStringResource, name: Binding<String>, colorHex: Binding<String>, nameID: String) -> some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            Text(title)
                .bscFont(size: 14, weight: .semibold)
                .foregroundColor(.bscTextSecondary)
                .textCase(.uppercase)

            TextField("Team name", text: name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(nameID)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: BSCTouchTarget.standard), spacing: BSCSpacing.sm)],
                alignment: .leading,
                spacing: BSCSpacing.sm
            ) {
                ForEach(GameTeamPalette.swatches) { swatch in
                    Button {
                        colorHex.wrappedValue = swatch.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: BSCIconSize.xl, height: BSCIconSize.xl)
                            .overlay(
                                Circle().stroke(
                                    colorHex.wrappedValue == swatch.hex ? Color.bscTextPrimary : .clear,
                                    lineWidth: 2.5
                                )
                                .padding(-BSCSpacing.xs)
                            )
                            .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(title) color: \(swatch.name)", comment: "Team color swatch; first %@ is Team 1/Team 2, second the color name"))
                    .accessibilityAddTraits(colorHex.wrappedValue == swatch.hex ? .isSelected : [])
                }
            }
        }
    }
}
