//
//  SamplerReviewChrome.swift
//  RallyLab
//
//  Everything around the frame being reviewed: the header (video, progress,
//  filters), the dark stage the frame sits on with its floating tag, action
//  bar and accept pulse, the "video done" banner, the filmstrip and the
//  shortcuts card. The frame and its boxes are ReviewCanvas.
//

import SwiftUI

enum ReviewStyle {
    /// Boxes you drew or confirmed.
    static let yours = Color(red: 0.2, green: 0.85, blue: 0.45)
    /// The detector's guesses, still to confirm.
    static let guess = Color(red: 1.0, green: 0.72, blue: 0.16)
    /// Balls carried over from earlier frames because they stayed put.
    static let held = Color(red: 0.25, green: 0.8, blue: 0.95)

    static func color(_ box: SampleBox) -> Color {
        box.held ? held : box.confidence == nil ? yours : guess
    }
    static let stage = Color(white: 0.085)

    static func sourceColor(_ source: FrameSample.Source) -> Color {
        switch source {
        case .rally: return .yellow
        case .missed: return .orange
        case .random: return .cyan
        case .file: return .purple
        }
    }

    static func sourceName(_ source: FrameSample.Source) -> String {
        switch source {
        case .rally(let i): return "Rally \(i + 1)"
        case .missed: return "Missed ball"
        case .random: return "Random"
        case .file: return "Still"
        }
    }
}

// MARK: - Header

struct ReviewHeader: View {
    @Bindable var sampler: SamplerModel
    let session: VideoSession
    @Binding var showSettings: Bool
    @Binding var showShortcuts: Bool
    let isFocused: Bool
    let toggleFocus: () -> Void

    var body: some View {
        let total = sampler.samples.count
        let reviewed = total - sampler.count(.unreviewed)
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(session.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    SplitBadge(split: session.split)
                }
                HStack(spacing: 8) {
                    ReviewProgress(value: total == 0 ? 0 : Double(reviewed) / Double(total))
                        .frame(width: 110)
                    Text("\(reviewed) of \(total) reviewed")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            FilterPills(sampler: sampler)
            HStack(spacing: 2) {
                HeaderIcon(icon: "arrow.up.arrow.down", isOn: sampler.lowestConfidenceFirst,
                           help: "Lowest confidence first") { sampler.lowestConfidenceFirst.toggle() }
                HeaderIcon(icon: "keyboard", isOn: showShortcuts, help: "Shortcuts (?)") { showShortcuts.toggle() }
                    .popover(isPresented: $showShortcuts, arrowEdge: .bottom) { ShortcutsCard() }
                if !isFocused {
                    HeaderIcon(icon: "sidebar.right", isOn: showSettings, help: "Sampling, dataset and training settings") {
                        withAnimation(.easeOut(duration: 0.2)) { showSettings.toggle() }
                    }
                }
                HeaderIcon(icon: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           isOn: isFocused, help: isFocused ? "Leave full screen (Esc)" : "Full screen (F)",
                           action: toggleFocus)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct SplitBadge: View {
    let split: String

    var body: some View {
        Text(split.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((split == "val" ? Color.purple : Color.secondary).opacity(0.18), in: Capsule())
            .foregroundStyle(split == "val" ? Color.purple : Color.secondary)
    }
}

struct ReviewProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(value >= 1 ? ReviewStyle.yours : Color.accentColor)
                    .frame(width: max(value > 0 ? 6 : 0, geo.size.width * value))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

private struct FilterPills: View {
    @Bindable var sampler: SamplerModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReviewFilter.allCases) { filter in
                let selected = sampler.filter == filter
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { sampler.filter = filter }
                } label: {
                    HStack(spacing: 5) {
                        Text(title(filter)).lineLimit(1)
                        Text("\(sampler.count(filter))")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background((selected ? Color.white : Color.primary).opacity(selected ? 0.25 : 0.08), in: Capsule())
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(selected ? Color.accentColor : .clear, in: Capsule())
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
    }

    private func title(_ filter: ReviewFilter) -> String {
        switch filter {
        case .all: return "All"
        case .unreviewed: return "To review"
        case .withBoxes: return "Ball"
        case .noBoxes: return "No ball"
        }
    }
}

private struct HeaderIcon: View {
    let icon: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background((isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.08 : 0)),
                            in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - On the stage

/// Where the frame came from and where it sits in the video.
struct FrameTag: View {
    let sample: FrameSample
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(ReviewStyle.sourceColor(sample.source)).frame(width: 7, height: 7)
            Text(ReviewStyle.sourceName(sample.source)).fontWeight(.semibold)
            if sample.source != .file {
                Text(String(format: "%.1f s", sample.time)).foregroundStyle(.secondary)
            }
            Text("\(position) / \(total)").foregroundStyle(.secondary)
            if sample.reviewed {
                if sample.keep && sample.boxes.isEmpty {
                    Label("No ball", systemImage: "circle.slash").foregroundStyle(.secondary)
                } else {
                    Image(systemName: sample.keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(sample.keep ? ReviewStyle.yours : .red)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The frame's actions, each with its key.
struct ReviewActionBar: View {
    @Bindable var sampler: SamplerModel
    let sample: FrameSample

    var body: some View {
        HStack(spacing: 4) {
            HUDButton(icon: sample.keep ? "eye.slash" : "eye", title: sample.keep ? "Discard" : "Keep", key: "K") {
                sampler.toggleKeep()
            }
            HUDButton(icon: "circle.slash", title: "No ball", key: "N") { sampler.markNoBallAndAdvance() }
            HUDButton(icon: "square.on.square", title: "Copy previous", key: "C") { sampler.carryBoxesForward() }
            HUDButton(icon: sampler.contextPlayer == nil ? "play.fill" : "stop.fill",
                      title: sampler.contextPlayer == nil ? "Play" : "Stop", key: "P") { sampler.toggleContext() }
                .disabled(!sampler.canShowContext)
            HUDButton(icon: "checkmark", title: "Accept", key: "↩", primary: true) { sampler.acceptAndAdvance() }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private struct HUDButton: View {
    let icon: String
    let title: String
    let key: String
    var primary = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.callout.weight(primary ? .semibold : .medium))
                Keycap(key, onColor: primary)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(background, in: Capsule())
            .foregroundStyle(primary ? Color.black.opacity(0.85) : Color.white)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var background: Color {
        primary ? ReviewStyle.yours.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.16 : 0.06)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct Keycap: View {
    let key: String
    var onColor = false

    init(_ key: String, onColor: Bool = false) {
        self.key = key
        self.onColor = onColor
    }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(onColor ? Color.black.opacity(0.15) : Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(onColor ? Color.black.opacity(0.15) : Color.white.opacity(0.18)))
    }
}

/// A check that pops over the stage when a frame is accepted.
struct AcceptPulse: View {
    let count: Int
    @State private var visible = false

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.black.opacity(0.8))
            .frame(width: 76, height: 76)
            .background(ReviewStyle.yours, in: Circle())
            .shadow(color: ReviewStyle.yours.opacity(0.5), radius: 20)
            .scaleEffect(visible ? 1 : 0.6)
            .opacity(visible ? 0.95 : 0)
            .allowsHitTesting(false)
            .onChange(of: count) {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { visible = true }
                withAnimation(.easeOut(duration: 0.3).delay(0.22)) { visible = false }
            }
    }
}

/// Shown once every frame of the video has been looked at.
struct VideoDoneBanner: View {
    @Bindable var sampler: SamplerModel
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(ReviewStyle.yours).font(.title3)
            Text("All \(total) frames reviewed").font(.callout.weight(.semibold))
            if let next = sampler.nextSessionToReview {
                Button {
                    sampler.openNextSession()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next: \(next.name)").lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right")
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(PressScale())
            } else {
                Text("Every video is done.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

// MARK: - Filmstrip

struct ReviewFilmstrip: View {
    @Bindable var sampler: SamplerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(sampler.visibleSamples) { s in
                        SampleThumb(sample: s, isSelected: s.id == sampler.selectedId)
                            .id(s.id)
                            .onTapGesture { sampler.select(s.id) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(height: 92)
            .onChange(of: sampler.selectedId) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear {
                if let id = sampler.selectedId { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsCard: View {
    private let rows: [(String, String)] = [
        ("← →", "Previous / next frame"),
        ("↩", "Accept and go to the next"),
        ("N", "No ball in this frame, next"),
        ("K", "Discard or keep the frame"),
        ("click", "Box the ball you click on"),
        ("drag", "Draw a box · move · resize at a corner"),
        ("⌫", "Delete the selected box"),
        ("C", "Copy the previous frame's boxes"),
        ("⇧ arrows", "Nudge the selected box"),
        ("⇧⌥ arrows", "Resize the selected box"),
        ("P", "Play ±0.75 s around the frame"),
        ("Z", "Zoom to the selected box"),
        ("= − 0", "Zoom in · out · fit"),
        ("pinch", "Zoom · scroll pans when zoomed"),
        ("⌘Z", "Undo"),
        ("F", "Full screen · Esc leaves it"),
        ("?", "Show these"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review shortcuts").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(rows, id: \.0) { key, what in
                    GridRow {
                        Text(key)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            .gridColumnAlignment(.trailing)
                        Text(what).font(.callout)
                    }
                }
            }
            HStack(spacing: 12) {
                legend(ReviewStyle.yours, dashed: false, "Yours")
                legend(ReviewStyle.guess, dashed: true, "Detector's guess")
                legend(ReviewStyle.held, dashed: true, "Held: stayed put")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func legend(_ color: Color, dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 10)
            Text(text)
        }
    }
}
