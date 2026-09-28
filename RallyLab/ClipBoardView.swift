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
import UniformTypeIdentifiers

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
    @State private var removing: PlannedClip?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(ClipKind.allCases, id: \.self) { kind in
                let group = clips.filter { $0.kind == kind }
                if !group.isEmpty || kind == .extra {
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
                                         note: { projects.note($0) },
                                         remove: kind == .extra ? { removing = clip } : nil)
                            }
                            if kind == .extra {
                                ExtrasDropTile(tint: tint, environment: name,
                                               add: { projects.addExtras($0, environment: name) },
                                               note: { projects.note($0) })
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.notes ?? "this extra")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { clip in
            Button("Remove Extra", role: .destructive) { projects.removeExtra(clip.id) }
        } message: { _ in
            Text("Its cut footage and any frames pulled from it are deleted. The original video isn't touched.")
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
    /// Only extras can be removed.
    var remove: (() -> Void)?
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

            if !clip.lighting.isEmpty || !clip.orientation.isEmpty {
                HStack(spacing: 6) {
                    if !clip.lighting.isEmpty { Chip(icon: clip.lightIcon, text: clip.lighting) }
                    if !clip.orientation.isEmpty {
                        Chip(icon: clip.orientation == "Portrait" ? "rectangle.portrait" : "rectangle",
                             text: clip.orientation)
                    }
                }
            }
            if clip.ball != "Any", !clip.ball.isEmpty {
                Chip(icon: "volleyball", text: clip.ball)
            }
            if !clip.notes.isEmpty, clip.kind != .extra {
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
        .contextMenu {
            if let remove { Button("Remove Extra…", role: .destructive, action: remove) }
        }
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

/// The slot for extra footage: drop any number of videos (Photos or
/// Finder), or click to choose them.
private struct ExtrasDropTile: View {
    let tint: Color
    let environment: String
    let add: ([URL]) -> Void
    let note: (String) -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(tint)
            Text("Drop extra videos").font(.headline)
            Text("As many as you like, or click to choose.\nThe first 5 minutes of each are sampled.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(tint.opacity(targeted ? 0.14 : (hovering ? 0.07 : 0.04)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(targeted ? 1 : 0.5),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [6, 4]))
        )
        .background(
            SamplerDropView(onDrop: add, onStatus: note,
                            onTargeted: { targeted = $0 }, onClick: choose)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .help("Extra \(environment.lowercased()) footage beyond the plan")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Extra \(environment.lowercased()) videos to sample from."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
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
    case recorded, negative, online, extra

    var heading: String {
        switch self {
        case .recorded: return "Record yourself"
        case .negative: return "Hard negatives — no rally, lots of distractions"
        case .online: return "From online footage (licensed)"
        case .extra: return "Extras — any other footage you want samples from"
        }
    }
}

extension PlannedClip {
    var kind: ClipKind {
        if id.contains("_extra_") { return .extra }
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
        case ProjectsModel.extraCamera: return "Extra footage"
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
        case ProjectsModel.extraCamera: return notes
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
        case ProjectsModel.extraCamera: return "film.stack"
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
