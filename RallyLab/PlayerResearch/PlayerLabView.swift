//
//  PlayerLabView.swift
//  RallyLab
//
//  The Player Lab window (player-feasibility research, P0): pick a run, a recording
//  and an interval; step or play through the sampled frames with the boxes, track
//  IDs, skeletons, unmatched poses, net and court lane toggled layer by layer; read
//  the frame's facts and the interval's numbers; see every track's lifespan (where
//  it starts, is confirmed, drops out and is flagged ambiguous) on a timeline that
//  also jumps to a frame. Snapshot saves the frame as PNG with its facts as JSON.
//

import AppKit
import SwiftUI

struct PlayerLabView: View {
    @Bindable var model: PlayerLabModel

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            VStack(alignment: .leading, spacing: 8) {
                picture
                transport
                layers
                HStack(alignment: .top, spacing: 16) {
                    frameFacts.frame(width: 300, alignment: .topLeading)
                    intervalStats
                }
                timeline.frame(height: min(240, CGFloat(max(model.tracks.count, 1)) * 9 + 24))
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(minWidth: 820)
        }
    }

    private var sidebar: some View {
        List {
            Section("Run") {
                Picker("Run", selection: $model.run) {
                    ForEach(model.runs) { Text($0.name).tag(Optional($0)) }
                }
                .labelsHidden()
            }
            Section("Recordings") {
                ForEach(model.manifest?.recordings ?? [], id: \.recordingId) { r in
                    Button { model.recordingId = r.recordingId } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.recordingId).font(.callout.monospaced()).fontWeight(model.recordingId == r.recordingId ? .bold : .regular)
                            Text("\(r.surface ?? "?") · \(r.camera ?? "?") · \(r.decoded.width)×\(r.decoded.height)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Intervals") {
                ForEach(model.recording?.intervals ?? [], id: \.name) { iv in
                    Button { model.intervalName = iv.name } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(iv.name) — \(iv.kind.rawValue)").fontWeight(model.intervalName == iv.name ? .bold : .regular)
                            Text(String(format: "%.1f–%.1f s", iv.startSec, iv.endSec)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let why = model.recording?.courtUnknownReason {
                Section("Court membership") { Text("unknown: \(why)").font(.caption) }
            }
        }
    }

    private var picture: some View {
        ZStack {
            Color.black
            if let image = model.composed {
                Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .frame(minHeight: 380)
    }

    private var transport: some View {
        HStack {
            Button { model.step(-1) } label: { Image(systemName: "backward.frame") }.keyboardShortcut(.leftArrow, modifiers: [])
            Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }.keyboardShortcut(.space, modifiers: [])
            Button { model.step(1) } label: { Image(systemName: "forward.frame") }.keyboardShortcut(.rightArrow, modifiers: [])
            Slider(value: Binding(get: { Double(model.index) }, set: { model.stop(); model.go(to: Int($0.rounded())) }),
                   in: 0...Double(max(model.frames.count - 1, 1)))
            Text("\(model.index + 1)/\(model.frames.count)").font(.caption.monospacedDigit()).frame(width: 64)
            Button("Snapshot") {
                let name = "\(model.recordingId ?? "")_\(model.intervalName ?? "")_\(model.frame?.tick ?? 0)"
                model.snapshot(name: name)
            }
        }
    }

    private var layers: some View {
        HStack(spacing: 12) {
            Toggle("Boxes", isOn: $model.options.boxes)
            Toggle("IDs", isOn: $model.options.labels)
            Toggle("Skeletons", isOn: $model.options.skeletons)
            Toggle("Unmatched poses", isOn: $model.options.unmatchedPoses)
            Toggle("Tentative", isOn: $model.options.tentative)
            Toggle("Off-court", isOn: $model.options.outOfCourt)
            Toggle("Net", isOn: $model.options.net)
            Toggle("Lane", isOn: $model.options.lane)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    private func num(_ v: Double?, _ f: String = "%.2f") -> String { v.map { String(format: f, $0) } ?? "—" }

    private var frameFacts: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let f = model.frame {
                Text(String(format: "t %.3f s · tick %d · seg %d", f.t, f.tick, f.seg)).font(.caption.monospaced())
                Text("reset: \(f.reset ?? "—") · frameDiff \(num(f.frameDiff, "%.3f"))").font(.caption)
                Text(f.masks.ran ? "analysed" : "not analysed (\(f.masks.skipped ?? "?"))").font(.caption)
                Text("persons \(f.persons.count) · confirmed \(f.scene.confirmed) · in court \(f.scene.inCourt) · poses \(f.persons.filter { $0.pose != nil }.count) · unmatched \(f.unmatchedPoses.count)")
                    .font(.caption)
                Text("rect \(num(f.ms["rect"], "%.1f")) ms · pose \(num(f.ms["pose"], "%.1f")) ms").font(.caption)
                Text("speed (in court) \(num(f.scene.meanSpeedInCourt)) · moving \(num(f.scene.movingShareInCourt)) · coherence \(num(f.scene.coherenceInCourt))")
                    .font(.caption)
            }
        }
    }

    private var intervalStats: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("Interval (model output, not accuracy)").font(.caption.bold())
            Text("frames \(s.frames) · analysed \(s.analysed) · persons/frame \(num(s.personsPerFrame)) · in court/frame \(num(s.inCourtPerFrame))").font(.caption)
            Text("pose share \(num(s.poseShare)) · joints/pose \(num(s.jointsPerPose, "%.1f")) · joint conf \(num(s.jointConfMean)) · unmatched/frame \(num(s.unmatchedPerFrame))").font(.caption)
            Text("tracks \(s.tracks) · confirmed \(s.confirmed) · tentative-only \(s.tentativeOnly) · mean confirmed length \(num(s.confirmedLengthMean, "%.1f")) frames · ambiguous \(num(s.ambiguousShare))").font(.caption)
            Text("resets \(s.resets.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))").font(.caption)
            Text("median rect \(num(s.rectMsMedian, "%.1f")) ms · pose \(num(s.poseMsMedian, "%.1f")) ms · box height \(num(s.boxHeightMedian, "%.3f"))").font(.caption)
        }
    }

    /// One row per track: where it was seen (thin before confirmation, thick after), ambiguous frames in red,
    /// segment starts as vertical lines, the current frame in white. A click jumps to that frame.
    private var timeline: some View {
        GeometryReader { geo in
            let n = max(model.frames.count, 1)
            let dx = geo.size.width / CGFloat(n)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.85)))
                for (i, f) in model.frames.enumerated() where f.reset != nil {
                    ctx.fill(Path(CGRect(x: CGFloat(i) * dx, y: 0, width: 1, height: size.height)), with: .color(.yellow.opacity(0.6)))
                }
                for (row, t) in model.tracks.enumerated() {
                    let y = 12 + CGFloat(row) * 9
                    let color = Color(cgColor: PlayerOverlay.color(t.id))
                    for i in t.frames {
                        let confirmed = t.confirmedFrom.map { i >= $0 } ?? false
                        ctx.fill(Path(CGRect(x: CGFloat(i) * dx, y: y + (confirmed ? 0 : 2), width: max(dx, 1), height: confirmed ? 6 : 2)), with: .color(color))
                    }
                    for i in t.ambiguous {
                        ctx.fill(Path(CGRect(x: CGFloat(i) * dx, y: y - 1, width: max(dx, 2), height: 8)), with: .color(.red))
                    }
                }
                ctx.fill(Path(CGRect(x: CGFloat(model.index) * dx, y: 0, width: max(dx, 2), height: size.height)), with: .color(.white.opacity(0.7)))
            }
            .contentShape(Rectangle())
            .onTapGesture { p in model.stop(); model.go(to: Int(p.x / dx)) }
        }
    }
}
