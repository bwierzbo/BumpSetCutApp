//
//  MarkRalliesView.swift
//  RallyLab (iPhone)
//
//  Mark every rally in a video in one pass, live, as the Mac does: watch
//  at ½–4× and tap one key per event. Serve starts a rally; Pass, Set,
//  Attack, Block, Free ball tag its touches; Dead ball ends it; Not a rally
//  ends it as a missed serve or other. Hold a key to say which side of the
//  net when the guess from the ball's size is wrong. Undo takes back the
//  last tap. The rules are LiveTagger's, shared with the Mac.
//
//  Pre-tracked rallies inside a rally you mark are confirmed and trimmed
//  to it. "That's every rally" turns down the ones you never marked, drops
//  the found rallies you passed over, and finishes the video.
//

import AVFoundation
import SwiftUI

struct MarkRalliesView: View {
    let model: LabelerModel
    let video: LabelVideo
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var rate: Float = 1
    @State private var observer: Any?
    @State private var loadError: String?
    @State private var url: URL?
    @State private var tagger: LiveTagger
    @State private var findingNet = false

    private static let speeds: [Float] = [0.5, 1, 2, 3, 4]

    init(model: LabelerModel, video: LabelVideo) {
        self.model = model
        self.video = video
        _tagger = State(initialValue: LiveTagger(tracks: model.tracks(for: video).map(\.rally), net: nil,
                                                 store: PhoneLiveTagStore(model: model, video: video)))
    }

    private var times: LabelRallyTimes { model.rallyTimes(for: video) }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay(alignment: .bottomLeading) { state.padding(8) }
                .overlay { if let loadError { Text(loadError).foregroundStyle(.white).padding() } }
            RallyTimesBar(time: time, duration: duration, found: video.ralliesFound, marked: times.rallies,
                          current: nil, pending: tagger.open?.first?.time,
                          ticks: (tagger.open ?? times.rallies.first { $0.start <= time && time <= $0.end }?.contacts ?? []).map(\.time))
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in seek(tap.location.x / max(barWidth, 1) * duration) })
                .background(GeometryReader { geo in Color.clear.onAppear { barWidth = geo.size.width }.onChange(of: geo.size.width) { _, w in barWidth = w } })
                .padding(.horizontal).padding(.top, 8)
            HStack {
                Text(clockText(time)).monospacedDigit()
                Spacer()
                if findingNet { ProgressView().controlSize(.mini); Text("Finding the net…") }
                else if tagger.net == nil { Text("No net found · hold a key to say the side") }
                Spacer()
                Text("\(times.rallies.count) marked").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 4)
            keys.padding(.horizontal).padding(.top, 10)
            transport.padding(.vertical, 8)
            list
        }
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task { await findNet() }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
            player.replaceCurrentItem(with: nil)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tagger.lastEventAt)
        .sensoryFeedback(.success, trigger: times.rallies.count)
    }

    @State private var barWidth: CGFloat = 1

    // MARK: - Live state

    /// Dead or in a rally, the touches so far, and the last tap.
    private var state: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let open = tagger.open {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Rally · \(clockText(open[0].time)) · \(open.count) \(open.count == 1 ? "touch" : "touches")")
                } else {
                    Circle().fill(.secondary).frame(width: 8, height: 8)
                    Text("Dead ball · Serve starts one")
                }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            if let open = tagger.open {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(open.enumerated()), id: \.offset) { _, c in
                            Text(c.kind.name + (c.side.map { " · \($0 == .near ? "near" : "far")" } ?? ""))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(c.kind == .serve ? Color.orange.opacity(0.35) : Color.white.opacity(0.15), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let note = tagger.recentNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 260, alignment: .leading)
    }

    // MARK: - Keys

    private var keys: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                key("Serve", "S", .orange) { tagger.serve(press($0)) }
                key("Pass", "P") { tagger.touch(.pass, press($0)) }
                key("Set", "T") { tagger.touch(.set, press($0)) }
            }
            HStack(spacing: 8) {
                key("Attack", "A") { tagger.touch(.attack, press($0)) }
                key("Block", "B") { tagger.touch(.block, press($0)) }
                key("Free ball", "F") { tagger.touch(.freeBall, press($0)) }
            }
            HStack(spacing: 8) {
                Button { tagger.close(as: .rally, press()) } label: { keyLabel("Dead ball", "D") }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button { tagger.close(as: nil, press()) } label: { keyLabel("Not a rally", "N") }
                    .buttonStyle(.bordered).tint(.red)
                Button { tagger.undo() } label: { keyLabel("Undo", "Z") }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    /// A touch key: tap for the side the ball's size says, hold to say it.
    private func key(_ name: String, _ k: String, _ tint: Color = .accentColor, action: @escaping (NetSide?) -> Void) -> some View {
        Menu {
            Button("Near side (camera's half)") { action(.near) }
            Button("Far side") { action(.far) }
        } label: {
            keyLabel(name, k)
        } primaryAction: {
            action(nil)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func keyLabel(_ name: String, _ k: String) -> some View {
        VStack(spacing: 1) {
            Text(k).font(.headline)
            Text(name).font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { seek(time - 2) } label: { Image(systemName: "gobackward") }
            Button(action: togglePlay) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2) }
            Button { seek(time + 2) } label: { Image(systemName: "goforward") }
            Picker("Speed", selection: $rate) {
                ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 230)
            .onChange(of: rate) { _, r in if isPlaying { player.rate = r } }
        }
        .font(.title3)
        .padding(.horizontal)
    }

    // MARK: - The marked rallies

    private var list: some View {
        List {
            Section {
                Button {
                    finish()
                } label: { Label("That's every rally", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(tagger.open != nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(tagger.open != nil ? "End the open rally first (Dead ball or Not a rally)."
                     : "Every rally in the video is marked: the found rallies you didn't mark are turned down and the video counts for scoring and the decision model.")
            }
            Section("Marked (\(times.rallies.count))") {
                ForEach(times.rallies) { r in
                    Button { play(from: r.start - 1) } label: {
                        HStack(spacing: 8) {
                            let kind = r.kind ?? .rally
                            Image(systemName: kind == .rally ? "figure.volleyball" : kind == .missedServe ? "xmark.circle" : "minus.circle")
                                .foregroundStyle(kind == .rally ? Color.orange : Color.secondary)
                                .frame(width: 18)
                            Text("\(clockText(r.start)) – \(clockText(r.end))").font(.callout.monospacedDigit())
                            Spacer()
                            Text(kind == .rally ? ((r.contacts ?? []).isEmpty ? String(format: "%.1f s", r.end - r.start)
                                                   : "\(r.contacts!.count) touches") : kind.name)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    let ids = offsets.map { times.rallies[$0].id }
                    model.update(video) { $0.rallies.removeAll { ids.contains($0.id) } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Presses

    private func press(_ side: NetSide? = nil) -> LiveTagger.Press {
        let now = player.currentTime().seconds
        return LiveTagger.Press(now: now.isFinite ? now : time, playing: player.rate > 0, rate: rate, side: side)
    }

    /// Everything you didn't mark isn't a rally: pre-tracked rallies are
    /// turned down, found rallies dropped; the video is finished.
    private func finish() {
        guard tagger.open == nil else { return }
        player.pause()
        isPlaying = false
        let marks = times.rallies
        func covered(_ a: Double, _ b: Double) -> Bool { marks.contains { min($0.end, b) - max($0.start, a) > 0.5 * (b - a) } }
        for t in model.tracks(for: video) where t.isMachine && t.isRally == nil && !covered(t.start, t.end) {
            model.setIsRally(false, AnnotationReview.RallyCheck(video: video.id.uuidString, track: t.id, start: t.start, end: t.end))
        }
        for f in model.openFound(in: video) where !covered(f[0], f[1]) {
            model.rejectFound(f, in: video)
        }
        model.update(video) { $0.complete = true }
        dismiss()
    }

    // MARK: - Player

    private func load() async {
        guard player.currentItem == nil else { return }
        do {
            let playback = try await model.playbackURL(for: video)
            url = playback
            let item = AVPlayerItem(url: playback)
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

    /// The net, once per visit, from the phone's copy of the video.
    private func findNet() async {
        guard tagger.net == nil, !findingNet else { return }
        let clip: URL
        do { clip = try await model.playbackURL(for: video) } catch { return }
        findingNet = true
        defer { findingNet = false }
        guard let found = await LiveTagger.findNet(in: clip) else { return }
        tagger.net = found.rect
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

    private func play(from t: Double) {
        seek(max(0, t))
        player.playImmediately(atRate: rate)
        isPlaying = true
    }
}

/// The phone's marks: the video's rally times, and its pre-tracked rallies
/// through the labeler model (sent frame by frame as the Mac's are).
@MainActor
final class PhoneLiveTagStore: LiveTagStore {
    let model: LabelerModel
    let video: LabelVideo

    init(model: LabelerModel, video: LabelVideo) {
        self.model = model
        self.video = video
    }

    func mark(start: Double, end: Double, kind: RallyKind, contacts: [RallyContact]) -> AnyHashable {
        let rally = LabelRally(start: start, end: end, kind: kind, contacts: contacts.isEmpty ? nil : contacts)
        model.update(video) { t in
            t.rallies.removeAll { $0.id == rally.id }
            t.rallies.append(rally)
        }
        return rally.id
    }

    func delete(_ mark: AnyHashable) {
        guard let id = mark as? String else { return }
        model.update(video) { $0.rallies.removeAll { $0.id == id } }
    }

    func confirmPretracked(start: Double, end: Double) -> [TrackedRally] {
        var before: [TrackedRally] = []
        for t in model.tracks(for: video) where t.isMachine && min(t.end, end) - max(t.start, start) > 0.5 * (t.end - t.start) {
            let rally = t.rally
            before.append(rally)
            let check = AnnotationReview.RallyCheck(video: video.id.uuidString, track: t.id, start: t.start, end: t.end)
            model.replace(check, with: rally.trimmed(start: start, end: end))
            model.setIsRally(true, check)
        }
        return before
    }

    func restore(_ rallies: [TrackedRally]) {
        for t in rallies {
            let check = AnnotationReview.RallyCheck(video: video.id.uuidString, track: t.id, start: t.start, end: t.end)
            model.replace(check, with: t)
            model.setIsRally(t.isRally, check)
        }
    }
}
