//
//  ClipBoardView.swift
//  RallyLab
//
//  The project's clip plan as a board rather than a spreadsheet: one
//  section per environment, each with its progress, and a card per clip
//  that says in plain words what footage it needs — where the camera is,
//  the light, the orientation, the ball — and where it stands. Selecting a
//  card opens it in the detail pane to give it footage.
//

import SwiftUI

struct ClipBoardView: View {
    @Bindable var projects: ProjectsModel

    private static let environments: [(name: String, icon: String, tint: Color)] = [
        ("Indoor", "building.2", .indigo),
        ("Beach", "beach.umbrella", .orange),
        ("Grass", "leaf", .green),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                ForEach(Self.environments, id: \.name) { env in
                    let clips = (projects.project?.clips ?? []).filter { $0.environment == env.name }
                    if !clips.isEmpty {
                        EnvironmentSection(projects: projects, name: env.name, icon: env.icon,
                                           tint: env.tint, clips: clips)
                    }
                }
            }
            .padding(16)
        }
        .background(.background.secondary)
    }
}

// MARK: - Environment section

private struct EnvironmentSection: View {
    @Bindable var projects: ProjectsModel
    let name: String
    let icon: String
    let tint: Color
    let clips: [PlannedClip]

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(ClipKind.allCases, id: \.self) { kind in
                let group = clips.filter { $0.kind == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.heading)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group) { clip in
                                ClipCard(clip: clip, tint: tint,
                                         progress: projects.progress(of: clip),
                                         isSelected: projects.selectedClipId == clip.id,
                                         select: { projects.selectedClipId = clip.id },
                                         drop: { projects.dropFootage($0, on: clip.id) },
                                         note: { projects.note($0) })
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        let done = clips.filter { if case .pulled(let f, let r) = projects.progress(of: $0) { return f > 0 && r == f }; return false }.count
        let footage = clips.filter { $0.source != nil }.count
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title2.weight(.bold))
                Text("\(clips.count) clips · \(footage) with footage · \(done) labeled")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            ProgressBar(footage: Double(footage) / Double(clips.count),
                        labeled: Double(done) / Double(clips.count), tint: tint)
                .frame(width: 200)
        }
    }
}

/// Two layers: how much has footage, and how much of that is labeled.
private struct ProgressBar: View {
    let footage: Double
    let labeled: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.35)).frame(width: geo.size.width * footage)
                Capsule().fill(tint).frame(width: geo.size.width * labeled)
            }
        }
        .frame(height: 8)
        .help("Light: has footage. Solid: fully labeled.")
    }
}

// MARK: - Card

private struct ClipCard: View {
    let clip: PlannedClip
    let tint: Color
    let progress: ClipProgress
    let isSelected: Bool
    let select: () -> Void
    let drop: ([URL]) -> Void
    let note: (String) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: clip.cameraIcon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.cameraTitle).font(.headline)
                    Text(clip.cameraDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if clip.split == "val" {
                    Text("VAL")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.18), in: Capsule())
                        .foregroundStyle(.purple)
                        .help("Held out to check the model")
                }
            }

            HStack(spacing: 6) {
                Chip(icon: clip.lightIcon, text: clip.lighting)
                Chip(icon: clip.orientation == "Portrait" ? "rectangle.portrait" : "rectangle",
                     text: clip.orientation)
            }
            if clip.ball != "Any", !clip.ball.isEmpty {
                Chip(icon: "volleyball", text: clip.ball)
            }
            if !clip.notes.isEmpty {
                Text(clip.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                ClipStatusLabel(progress: progress).font(.caption)
                Spacer()
                Text(clip.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? tint : Color.primary.opacity(hovering ? 0.18 : 0.08),
                              lineWidth: isSelected ? 2 : 1)
        )
        .overlay(alignment: .leading) {
            // A status stripe: grey nothing yet, tint in progress, green done.
            RoundedRectangle(cornerRadius: 2)
                .fill(stripe)
                .frame(width: 4)
                .padding(.vertical, 14)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.12))
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay {
                        Label(dropHint, systemImage: "square.and.arrow.down")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.background, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        // AppKit drop target, so videos dragged from Photos (file promises)
        // land on the card as well as ones from Finder.
        .background(
            SamplerDropView(onDrop: drop, onStatus: note,
                            onTargeted: { dropTargeted = $0 }, onClick: select)
        )
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 6 : 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    private var dropHint: String {
        if clip.source != nil { return "Drop to choose replacement" }
        return clip.kind == .online ? "Drop, then add licence" : "Drop to get clip"
    }

    private var stripe: Color {
        switch progress {
        case .notStarted: return .clear
        case .failed: return .red
        case .cutting, .sampling: return tint.opacity(0.5)
        case .pulled(let frames, let reviewed): return frames > 0 && reviewed == frames ? .green : tint
        }
    }
}

private struct Chip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Plain-language descriptions

enum ClipKind: CaseIterable {
    case recorded, negative, online

    var heading: String {
        switch self {
        case .recorded: return "Record yourself"
        case .negative: return "Hard negatives — no rally, lots of distractions"
        case .online: return "From online footage (licensed)"
        }
    }
}

extension PlannedClip {
    var kind: ClipKind {
        if id.contains("_neg_") { return .negative }
        if id.contains("_onl_") { return .online }
        return .recorded
    }

    var cameraTitle: String {
        switch camera {
        case let c where c.contains("elevated"): return "End line, raised"
        case let c where c.contains("ground"): return "End line, ground level"
        case let c where c.hasPrefix("Sideline"): return "Sideline, near the net"
        case let c where c.hasPrefix("Handheld"): return "Handheld from a corner"
        case let c where c.hasPrefix("Hard negative"): return "No rally"
        case let c where c.hasPrefix("Online"): return "Online clip"
        default: return camera
        }
    }

    var cameraDetail: String {
        switch camera {
        case let c where c.contains("elevated"): return "Stands or a tripod, 2 m or higher"
        case let c where c.contains("ground"): return "Phone at standing height behind the court"
        case let c where c.hasPrefix("Sideline"): return "Side-on view across the court"
        case let c where c.hasPrefix("Handheld"): return "Moving camera, not locked off"
        case let c where c.hasPrefix("Hard negative"): return "Things that aren't a game ball"
        case let c where c.hasPrefix("Online"): return "Creative Commons or with permission"
        default: return ""
        }
    }

    var cameraIcon: String {
        switch camera {
        case let c where c.contains("elevated"): return "arrow.up.circle"
        case let c where c.contains("ground"): return "arrow.down.circle"
        case let c where c.hasPrefix("Sideline"): return "arrow.left.and.right.circle"
        case let c where c.hasPrefix("Handheld"): return "hand.raised"
        case let c where c.hasPrefix("Hard negative"): return "exclamationmark.triangle"
        case let c where c.hasPrefix("Online"): return "globe"
        default: return "video"
        }
    }

    var lightIcon: String {
        switch lighting {
        case "Bright gym": return "lightbulb.max"
        case "Dim gym": return "lightbulb.min"
        case "Sunny": return "sun.max"
        case "Shade": return "tree"
        case "Dusk": return "sunset"
        case let l where l.hasPrefix("Overcast"): return "cloud.sun"
        default: return "light.max"
        }
    }
}
