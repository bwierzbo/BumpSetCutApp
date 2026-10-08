//
//  RallyTimesView.swift
//  Labeler
//
//  Mark every rally's start and end in one video, as RallyLab's Track →
//  Rally times does: play or scrub, "Rally starts" at the serve, "Rally
//  ends" when the ball is dead. RallyLab's found rallies are shown under
//  the timeline and can be taken as a starting point. "Every rally marked"
//  makes the video count for scoring rally cutting. Saved as you go.
//

import AVFoundation
import SwiftUI

struct RallyTimesView: View {
    let model: LabelerModel
    let video: LabelVideo

    @State private var player = AVPlayer()
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var rate: Float = 1
    @State private var pendingStart: Double?
    @State private var selected: LabelRally.ID?
    @State private var observer: Any?
    @State private var loadError: String?
    /// The rally being trimmed (BumpSetCut's trim bar), and the clip it plays.
    @State private var trimming: LabelRally?
    @State private var url: URL?

    /// RallyLab reads frames 1/30 s apart; a frame step is one of those.
    private let frame = 1.0 / 30

    private var times: LabelRallyTimes { model.rallyTimes(for: video) }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay { if let loadError { Text(loadError).foregroundStyle(.white).padding() } }
            timeline.padding(.horizontal).padding(.top, 10)
            controls.padding(.vertical, 8)
            markButtons.padding(.horizontal)
            list
        }
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $trimming) { rally in
            if let url {
                RallyTrimView(video: video, rally: rally, url: url, onConfirm: { trimmed in
                    move(rally.id) { $0.start = trimmed.start; $0.end = trimmed.end }
                    // A rally's id is its times: keep the trimmed one selected.
                    selected = trimmed.id
                    trimming = nil
                }, onCancel: { trimming = nil })
            }
        }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    // MARK: - Player

    private func load() async {
        guard player.currentItem == nil else { return }
        do {
            let url = try await model.playbackURL(for: video)
            self.url = url
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            duration = (try? await item.asset.load(.duration).seconds) ?? video.duration
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                time = t.seconds
                isPlaying = player.rate > 0
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func seek(_ t: Double) {
        let target = min(max(0, t), max(duration, 0))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else { player.playImmediately(atRate: rate) }
        isPlaying.toggle()
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { time }, set: { seek($0) }), in: 0...max(duration, 0.1))
            GeometryReader { geo in
                let w = geo.size.width, d = max(duration, 0.1)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(video.ralliesFound.enumerated()), id: \.offset) { _, r in
                        Capsule().fill(Color.secondary.opacity(0.35))
                            .frame(width: max(2, (r[1] - r[0]) / d * w), height: 5)
                            .offset(x: r[0] / d * w, y: 0)
                    }
                    ForEach(times.rallies) { r in
                        Capsule().fill(r.id == selected ? Color.accentColor : Color.orange)
                            .frame(width: max(2, (r.end - r.start) / d * w), height: 7)
                            .offset(x: r.start / d * w, y: 7)
                    }
                    if let pendingStart {
                        Capsule().fill(Color.orange.opacity(0.5))
                            .frame(width: max(2, (time - pendingStart) / d * w), height: 7)
                            .offset(x: pendingStart / d * w, y: 7)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text(Self.clock(time)).monospacedDigit()
                Spacer()
                Text("grey: found by RallyLab · orange: yours").foregroundStyle(.secondary)
                Spacer()
                Text(Self.clock(duration)).monospacedDigit()
            }
            .font(.caption2)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button { seek(time - 2) } label: { Image(systemName: "gobackward") }
            Button { player.pause(); isPlaying = false; seek(time - frame) } label: { Image(systemName: "backward.frame") }
            Button(action: togglePlay) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2) }
            Button { player.pause(); isPlaying = false; seek(time + frame) } label: { Image(systemName: "forward.frame") }
            Button { seek(time + 2) } label: { Image(systemName: "goforward") }
            Menu {
                ForEach([Float(0.5), 1, 2], id: \.self) { r in
                    Button("\(r == 1 ? "1" : r == 2 ? "2" : "½")×") {
                        rate = r
                        if isPlaying { player.rate = r }
                    }
                }
            } label: { Text("\(rate == 1 ? "1" : rate == 2 ? "2" : "½")×").monospacedDigit() }
        }
        .font(.title3)
    }

    // MARK: - Marking

    private var markButtons: some View {
        HStack(spacing: 10) {
            if let pendingStart {
                Button {
                    let start = pendingStart, end = time
                    guard end > start + 0.2 else { return }
                    let rally = LabelRally(start: start, end: end)
                    model.update(video) { $0.rallies.append(rally) }
                    selected = rally.id
                    self.pendingStart = nil
                } label: { Label("Rally ends", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.orange)
                Button("Cancel") { self.pendingStart = nil }.buttonStyle(.bordered)
            } else {
                Button {
                    pendingStart = time
                } label: { Label("Rally starts", systemImage: "flag").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private var list: some View {
        List {
            Section {
                Toggle("Every rally marked", isOn: Binding(get: { times.complete },
                                                           set: { v in model.update(video) { $0.complete = v } }))
            } footer: {
                Text("Turn on when every rally in the video is marked: then it counts for scoring rally cutting.")
            }
            Section("Yours (\(times.rallies.count))") {
                ForEach(times.rallies) { r in
                    rallyRow(r)
                }
                .onDelete { offsets in
                    let ids = offsets.map { times.rallies[$0].id }
                    model.update(video) { $0.rallies.removeAll { ids.contains($0.id) } }
                }
            }
            let open = video.ralliesFound.filter { f in
                !times.rallies.contains { min($0.end, f[1]) - max($0.start, f[0]) > 0.3 }
            }
            if !open.isEmpty {
                Section("Found by RallyLab, not marked yet") {
                    ForEach(Array(open.enumerated()), id: \.offset) { _, f in
                        HStack {
                            Button("\(Self.clock(f[0])) – \(Self.clock(f[1]))") { seek(f[0]) }
                                .font(.callout.monospacedDigit())
                            Spacer()
                            Button("Use") {
                                let rally = LabelRally(start: f[0], end: f[1])
                                model.update(video) { $0.rallies.append(rally) }
                                selected = rally.id
                                seek(f[0])
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rallyRow(_ r: LabelRally) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                selected = r.id
                seek(r.start)
            } label: {
                HStack {
                    Text("\(Self.clock(r.start)) – \(Self.clock(r.end))").font(.callout.monospacedDigit())
                    Spacer()
                    Text(String(format: "%.1f s", r.end - r.start)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
            if selected == r.id {
                HStack {
                    Button { player.pause(); isPlaying = false; trimming = r } label: { Label("Trim", systemImage: "timeline.selection") }
                    Spacer()
                    Button("Play from start") { seek(r.start); player.playImmediately(atRate: rate); isPlaying = true }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func move(_ id: LabelRally.ID, _ change: @escaping (inout LabelRally) -> Void) {
        model.update(video) { t in
            if let i = t.rallies.firstIndex(where: { $0.id == id }) { change(&t.rallies[i]) }
        }
    }

    static func clock(_ t: Double) -> String {
        guard t.isFinite else { return "0:00.0" }
        return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// An AVPlayer's picture, without system controls.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
