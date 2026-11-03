//
//  MarkRalliesView.swift
//  RallyLab (iPhone)
//
//  Mark every rally in a video in one pass, live, as the Mac does: watch
//  at ½–4× and tap one key per event. Serve starts a rally; Dead ball ends
//  it; Missed serve and Not a rally end it as one of those. Cut takes out
//  a stretch that is not footage (an instant replay), from one tap to the
//  next; Starts mid-rally cuts from the clip's start to the next serve
//  (D-030). Undo takes back the last tap. The touches inside a rally are
//  advanced marking, not part of this pass (D-028). The rules are
//  LiveTagger's, shared with the Mac.
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

    private static let speeds: [Float] = [0.5, 1, 2, 3, 4]

    init(model: LabelerModel, video: LabelVideo) {
        self.model = model
        self.video = video
        _tagger = State(initialValue: LiveTagger(tracks: model.tracks(for: video).map(\.rally),
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
                          current: nil, pending: tagger.open,
                          ticks: times.rallies.first { $0.start <= time && time <= $0.end }?.contacts?.map(\.time) ?? [],
                          cuts: (times.cuts ?? []).map { [$0.start, $0.end] }, pendingCut: tagger.cutFrom)
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in seek(tap.location.x / max(barWidth, 1) * duration) })
                .background(GeometryReader { geo in Color.clear.onAppear { barWidth = geo.size.width }.onChange(of: geo.size.width) { _, w in barWidth = w } })
                .padding(.horizontal).padding(.top, 8)
            HStack {
                Text(clockText(time)).monospacedDigit()
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

    /// Dead or in a rally, and the last tap.
    private var state: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let from = tagger.cutFrom {
                    Circle().fill(.black).frame(width: 8, height: 8)
                    Text("Cut from \(from == 0 ? "the start" : clockText(from)) · Cut ends it, Serve too")
                } else if let open = tagger.open {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Rally · served at \(clockText(open))")
                } else {
                    Circle().fill(.secondary).frame(width: 8, height: 8)
                    Text("Dead ball · Serve starts one")
                }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            if let note = tagger.recentNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            } else if duration > 0 {
                let covered = tagger.path.stretches.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                Text("Snaps to the ball on \(Int(min(1, covered / duration) * 100))% of the video")
                    .font(.caption2).foregroundStyle(.secondary)
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
                Button { tagger.serve(press()) } label: { keyLabel("Serve", "S") }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Button { tagger.close(as: .rally, press()) } label: { keyLabel("Dead ball", "D") }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
            HStack(spacing: 8) {
                Button { tagger.close(as: .missedServe, press()) } label: { keyLabel("Missed serve", "M") }
                    .buttonStyle(.bordered).tint(.red)
                Button { tagger.close(as: .other, press()) } label: { keyLabel("Not a rally", "N") }
                    .buttonStyle(.bordered).tint(.red)
                Button { tagger.undo() } label: { keyLabel("Undo", "Z") }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Button { tagger.cut(press()) } label: { keyLabel("Cut", "X") }
                    .buttonStyle(.bordered).tint(.gray)
                Button { tagger.cutFromStart() } label: { keyLabel("Starts mid-rally", "⇧X") }
                    .buttonStyle(.bordered).tint(.gray)
            }
        }
        .controlSize(.large)
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
                    .disabled(tagger.open != nil || tagger.cutFrom != nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(tagger.cutFrom != nil ? "End the open cut first (Cut, or Serve at the next rally)."
                     : tagger.open != nil ? "End the open rally first (Dead ball or Not a rally)."
                     : "Every rally in the video is marked: the found rallies you didn't mark are turned down and the video counts for scoring and the decision model.")
            }
            if let cuts = times.cuts, !cuts.isEmpty {
                Section("Cut out (\(cuts.count))") {
                    ForEach(cuts, id: \.self) { c in
                        Button { play(from: c.start - 1) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "scissors").foregroundStyle(.secondary).frame(width: 18)
                                Text("\(clockText(c.start)) – \(clockText(c.end))").font(.callout.monospacedDigit())
                                Spacer()
                                Text(String(format: "%.1f s not footage", c.end - c.start)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        let gone = offsets.map { cuts[$0] }
                        model.update(video) { $0.cuts?.removeAll { gone.contains($0) } }
                    }
                }
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

    private func press() -> LiveTagger.Press {
        let now = player.currentTime().seconds
        return LiveTagger.Press(now: now.isFinite ? now : time, playing: player.rate > 0, rate: rate)
    }

    /// Everything you didn't mark isn't a rally: pre-tracked rallies are
    /// turned down, found rallies dropped — except inside a cut range, which
    /// is not footage and is left alone (D-030); the video is finished.
    private func finish() {
        guard tagger.open == nil, tagger.cutFrom == nil else { return }
        player.pause()
        isPlaying = false
        let marks = times.rallies
        let cuts = times.cutRanges
        func covered(_ a: Double, _ b: Double) -> Bool { marks.contains { min($0.end, b) - max($0.start, a) > 0.5 * (b - a) } }
        for t in model.tracks(for: video) where t.isMachine && t.isRally == nil && !covered(t.start, t.end) && !cuts.overlaps(t.start, t.end) {
            model.setIsRally(false, AnnotationReview.RallyCheck(video: video.id.uuidString, track: t.id, start: t.start, end: t.end))
        }
        for f in model.openFound(in: video) where !covered(f[0], f[1]) && !cuts.overlaps(f[0], f[1]) {
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
            if let seen = await model.ballPath(for: video) {
                tagger.path = BallPath(tracks: model.tracks(for: video).map(\.rally), seen: seen)
            }
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

    func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable {
        let rally = LabelRally(start: start, end: end, kind: kind)
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

    func marks(overlapping start: Double, _ end: Double) -> [LiveTagger.ExistingMark] {
        model.rallyTimes(for: video).rallies.filter { min($0.end, end) - max($0.start, start) > 0 }.map {
            LiveTagger.ExistingMark(handle: $0.id, start: $0.start, end: $0.end, kind: $0.kind, contacts: $0.contacts)
        }
    }

    func restoreMark(_ mark: LiveTagger.ExistingMark) -> AnyHashable {
        let rally = LabelRally(start: mark.start, end: mark.end, kind: mark.kind, contacts: mark.contacts)
        model.update(video) { t in
            t.rallies.removeAll { $0.id == rally.id }
            t.rallies.append(rally)
        }
        return rally.id
    }

    func cut(start: Double, end: Double) -> AnyHashable {
        let range = CutRange(start: start, end: end)
        model.update(video) { $0.cuts = ($0.cuts ?? []) + [range] }
        return range
    }

    func uncut(_ cut: AnyHashable) {
        guard let range = cut as? CutRange else { return }
        model.update(video) { t in
            if let i = t.cuts?.firstIndex(of: range) { t.cuts?.remove(at: i) }
        }
    }
}
